{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE UnicodeSyntax #-}
{-# LANGUAGE ViewPatterns #-}

module HabitOfFate.Server
  ( makeApp
  -- Messages
  , no_username_message
  , no_password_message
  , no_password2_message
  , password_mismatch_message
  , account_exists_message
  ) where

import HabitOfFate.Prelude hiding (div, id, log)

import Data.Aeson hiding ((.=))
import Control.Concurrent
import Control.Concurrent.STM
import Control.DeepSeq
import Control.Exception (SomeException, assert, catch, throwIO)
import Control.Monad.Operational (Program, ProgramViewT(..))
import qualified Control.Monad.Operational as Operational
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Text.Lazy as Lazy
import Data.UUID
import Data.Yaml hiding (Parser, (.=))
import GHC.Conc
import Network.HTTP.Types.Status
import Network.Wai
import System.IO (BufferMode(LineBuffering), hSetBuffering, stderr)
import Text.Blaze.Html5
  ( (!)
  , body
  , button
  , docTypeHtml
  , div
  , form
  , head
  , input
  , p
  , span
  , table
  , td
  , title
  , toHtml
  , toValue
  , tr
  )
import Text.Blaze.Html5.Attributes
  ( action
  , id
  , method
  , name
  , type_
  , value
  )
import Text.Blaze.Html.Renderer.Text (renderHtml)
import Web.JWT hiding (decode, header)
import Web.Scotty
  ( ActionM
  , Param
  , Parsable
  , params
  , parseParam
  , finish
  , rescue
  , scottyApp
  , status
  )
import qualified Web.Scotty as Scotty

import HabitOfFate.Account hiding (_habits)
import HabitOfFate.Credits
import HabitOfFate.Logging
import HabitOfFate.Story

--------------------------------------------------------------------------------
-------------------------------- Miscellaneous ---------------------------------
--------------------------------------------------------------------------------

instance Parsable UUID where
  parseParam = maybe (Left "badly formed UUID") Right ∘ fromText ∘ view strict

data Environment = Environment
  { accounts_tvar ∷ TVar (Map Text (TVar Account))
  , password_secret ∷ Secret
  , expected_iss ∷ StringOrURI
  , write_request_var ∷ TMVar ()
  }

--------------------------------------------------------------------------------
---------------------------- Shared Scotty Actions -----------------------------
--------------------------------------------------------------------------------

----------------------------------- Queries ------------------------------------

lookupHabit habit_id = do
  use (habits . at habit_id)
  >>=
  maybe raiseNoSuchHabit return

param ∷ Parsable α ⇒ Lazy.Text → ActionM α
param name =
  Scotty.param name
  `rescue`
  (const
   $
   do Scotty.text $ "Missing parameter: \"" ⊕ name ⊕ "\""
      status badRequest400
      finish
  )

paramOrBlank ∷ Lazy.Text → ActionM Text
paramOrBlank name = Scotty.param name `rescue` (const ∘ pure $ "")

bodyJSON ∷ FromJSON α ⇒ ActionM α
bodyJSON = do
  body_ ← Scotty.body
  case eitherDecode' body_ of
    Left message → do
      logIO [i|Error parsing JSON for reason "#{message}#:\n#{decodeUtf8 body_}|]
      finishWithStatusMessage 400 "Bad request: Invalid JSON"
    Right value → pure value

data CreateAccountResult = AccountExists | AccountCreated deriving (Eq,Show,Ord,Read)

authorizeWith ∷ Environment → ActionM (String, TVar Account)
authorizeWith Environment{..} =
  Scotty.header "Authorization"
  >>=
  maybe
    (finishWithStatusMessage 403 "Forbidden: No authorization token.")
    return
  >>=
  \case
    (words → ["Bearer", token]) → return token
    header →
      finishWithStatusMessage
        403
        [i|Forbidden: Unrecognized authorization header: #{header}|]
  >>=
  maybe
    (finishWithStatusMessage 403 "Forbidden: Unable to verify key")
    return
  ∘
  decodeAndVerifySignature password_secret
  ∘
  view strict
  >>=
  (\case
    (claims → JWTClaimsSet { iss = Just observed_iss, sub = Just username })
      | observed_iss == expected_iss →
          ((fmap ∘ lookup ∘ pack ∘ show $ username) ∘ liftIO ∘ readTVarIO $ accounts_tvar)
          >>=
          maybe
            (finishWithStatusMessage 404 "Not Found: No such account")
            (pure ∘ (show username,))
    _ → finishWithStatusMessage 403 "Forbidden: Token does not grant access to this resource"
  )

----------------------------------- Results ------------------------------------

finishWithStatus ∷ Status → ActionM α
finishWithStatus s = do
  logIO $ "Finished with status: " ⊕ show s
  status s
  finish

finishWithStatusMessage ∷ Int → String → ActionM α
finishWithStatusMessage code = finishWithStatus ∘ Status code ∘ encodeUtf8 ∘ pack

setContent ∷ Content → ActionM ()
setContent NoContent = pure ()
setContent (TextContent t) = Scotty.text t
setContent (JSONContent j) = Scotty.json j

setStatusAndLog ∷ Status → ActionM ()
setStatusAndLog status_@(Status code message) = do
  status status_
  let result
        | code < 200 || code >= 300 = "failed"
        | otherwise = "succeeded"
  logIO $ [i|Request #{result} - #{code} #{unpack ∘ decodeUtf8 $ message}|]

data ProgramResult = ProgramResult Status Content

data Content =
    NoContent
  | TextContent Lazy.Text
  | ∀ α. ToJSON α ⇒ JSONContent α

returnNothing ∷ Monad m ⇒ Status → m ProgramResult
returnNothing s = return $ ProgramResult s NoContent

returnLazyText ∷ Monad m ⇒ Status → Lazy.Text → m ProgramResult
returnLazyText s = return ∘ ProgramResult s ∘ TextContent

returnText ∷ Monad m ⇒ Status → Text → m ProgramResult
returnText s = returnLazyText s ∘ view (from strict)

returnJSON ∷ (ToJSON α, Monad m) ⇒ Status → α → m ProgramResult
returnJSON s = return ∘ ProgramResult s ∘ JSONContent

logRequest ∷ ActionM ()
logRequest = do
  r ← Scotty.request
  logIO $ [i|URL requested: #{requestMethod r} #{rawPathInfo r}#{rawQueryString r}|]

--------------------------------------------------------------------------------
--------------------------------- Action Monad ---------------------------------
--------------------------------------------------------------------------------

------------------------------------ Common ------------------------------------

data CommonInstructionInstruction α where
  GetBodyInstruction ∷ CommonInstructionInstruction Lazy.ByteString
  GetParamsInstruction ∷ CommonInstructionInstruction [Param]
  RaiseStatusInstruction ∷ Status → CommonInstructionInstruction α
  LogInstruction ∷ String → CommonInstructionInstruction ()

class Monad m ⇒ ActionMonad m where
  singletonCommon ∷ CommonInstructionInstruction α → m α

getBody ∷ ActionMonad m ⇒ m Lazy.ByteString
getBody = singletonCommon GetBodyInstruction

getBodyJSON ∷ (FromJSON α, ActionMonad m) ⇒ m α
getBodyJSON = do
  body ← getBody
  case eitherDecode' $ body of
    Left message → do
      log [i|Error parsing JSON for reason "#{message}#:\n#{decodeUtf8 body}|]
      raiseStatus 400 "Bad request: Invalid JSON"
    Right json → pure json

getParams ∷ ActionMonad m ⇒ m [Param]
getParams = singletonCommon GetParamsInstruction

getParam ∷ (Parsable α, ActionMonad m) ⇒ Lazy.Text → m α
getParam param_name = do
  params_ ← getParams
  case lookup param_name params_ of
    Nothing → raiseStatus 400 [i|Bad request: Missing parameter %{param_name}|]
    Just value → case parseParam value of
      Left _ →
        raiseStatus
          400
          [i|Bad request: Parameter #{param_name} has invalid format #{value}|]
      Right x → return x

raiseStatus ∷ ActionMonad m ⇒ Int → String → m α
raiseStatus code =
  singletonCommon
  ∘
  RaiseStatusInstruction
  ∘
  Status code
  ∘
  encodeUtf8
  ∘
  pack

raiseNoSuchHabit = raiseStatus 404 "Not found: No such habit"

log ∷ ActionMonad m ⇒ String → m ()
log = singletonCommon ∘ LogInstruction

------------------------------------ Reader ------------------------------------

data ReaderInstruction α where
  ReaderCommonInstruction ∷ CommonInstructionInstruction α → ReaderInstruction α
  ReaderViewInstruction ∷ ReaderInstruction Account

newtype ReaderProgram α = ReaderProgram
  { unwrapReaderProgram ∷ Program ReaderInstruction α }
  deriving (Applicative, Functor, Monad)

instance ActionMonad ReaderProgram where
  singletonCommon = ReaderProgram ∘ Operational.singleton ∘ ReaderCommonInstruction

instance MonadReader Account (ReaderProgram) where
  ask = ReaderProgram $ Operational.singleton ReaderViewInstruction
  local = error "if you see this, then ReaderProgram needs to have a local method"

readerWith ∷ Environment → ReaderProgram ProgramResult → ActionM ()
readerWith environment (ReaderProgram program) = do
  logRequest
  (username, account_tvar) ← authorizeWith environment
  params_ ← params
  body_ ← Scotty.body
  account ← liftIO ∘ readTVarIO $ account_tvar
  let interpret ∷
        Program ReaderInstruction α →
        ExceptT Status (Writer (Seq String)) α
      interpret (Operational.view → Return result) = pure result
      interpret (Operational.view → instruction :>>= rest) = case instruction of
        ReaderCommonInstruction common_instruction → case common_instruction of
          GetBodyInstruction → interpret (rest body_)
          GetParamsInstruction → interpret (rest params_)
          RaiseStatusInstruction s → throwError s
          LogInstruction message → do
            tell ∘ singleton $ [i|[#{username}]: #{message}|]
            interpret (rest ())
        ReaderViewInstruction → interpret (rest account)
      (error_or_result, logs) = runWriter ∘ runExceptT ∘ interpret $ program
  traverse_ logIO logs
  case error_or_result of
    Left status_ →
      setStatusAndLog status_
    Right (ProgramResult status_ content) → do
      setStatusAndLog status_
      setContent content

------------------------------------ Writer ------------------------------------

data WriterInstruction α where
  WriterCommonInstruction ∷ CommonInstructionInstruction α → WriterInstruction α
  WriterGetAccountInstruction ∷ WriterInstruction Account
  WriterPutAccountInstruction ∷ Account → WriterInstruction ()

newtype WriterProgram α = WriterProgram
  { unwrapWriterProgram ∷ Program WriterInstruction α }
  deriving (Applicative, Functor, Monad)

instance ActionMonad WriterProgram where
  singletonCommon = WriterProgram ∘ Operational.singleton ∘ WriterCommonInstruction

instance MonadState Account WriterProgram where
  get = WriterProgram $ Operational.singleton WriterGetAccountInstruction
  put = WriterProgram ∘ Operational.singleton ∘ WriterPutAccountInstruction

writerWith ∷ Environment → WriterProgram ProgramResult → ActionM ()
writerWith (environment@Environment{..}) (WriterProgram program) = do
  logRequest
  (username, account_tvar) ← authorizeWith environment
  params_ ← params
  body_ ← Scotty.body
  let interpret ∷
        Program WriterInstruction α →
        StateT Account (ExceptT Status (Writer (Seq String))) α
      interpret (Operational.view → Return result) = pure result
      interpret (Operational.view → instruction :>>= rest) = case instruction of
        WriterCommonInstruction common_instruction → case common_instruction of
          GetBodyInstruction → interpret (rest body_)
          GetParamsInstruction → interpret (rest params_)
          RaiseStatusInstruction s → throwError s
          LogInstruction message → do
            tell ∘ singleton $ [i|[#{username}]: #{message}|]
            interpret (rest ())
        WriterGetAccountInstruction → get >>= interpret ∘ rest
        WriterPutAccountInstruction new_account → put new_account >> interpret (rest ())
  (status_, maybe_content, logs) ← liftIO ∘ atomically $ do
    old_account ← readTVar account_tvar
    let (error_or_result, logs) =
          runWriter
          ∘
          runExceptT
          ∘
          flip runStateT old_account
          $
          interpret program
    case error_or_result of
      Left status_ → pure (status_, Nothing, logs)
      Right (ProgramResult status_ content, new_account) → do
        writeTVar account_tvar new_account
        tryPutTMVar write_request_var ()
        pure (status_, Just content, logs)
  traverse_ logIO logs
  setStatusAndLog status_
  maybe (pure ()) setContent maybe_content

--------------------------------------------------------------------------------
----------------------------------- Messages -----------------------------------
--------------------------------------------------------------------------------

no_username_message = "No username was provided."
no_password_message = "No password was provided."
no_password2_message = "You need to repeat the password."
password_mismatch_message = "The password do not match."
account_exists_message = "The account already exists."

--------------------------------------------------------------------------------
------------------------------ Server Application ------------------------------
--------------------------------------------------------------------------------

makeApp ∷
  Secret →
  Map Text Account →
  (Map Text Account → IO ()) →
  IO Application
makeApp password_secret initial_accounts saveAccounts = do
----------------------------------- Prelude ------------------------------------
  liftIO $ hSetBuffering stderr LineBuffering

  logIO $ "Starting server..."

  accounts_tvar ∷ TVar (Map Text (TVar Account)) ← atomically $
    traverse newTVar initial_accounts >>= newTVar

  write_request_var ← newEmptyTMVarIO
  forkIO ∘ forever $
    (atomically $ do
      takeTMVar write_request_var
      readTVar accounts_tvar >>= traverse readTVar
    )
    >>=
    saveAccounts

  let expected_iss = fromJust $ stringOrURI "habit-of-fate"
      environment = Environment{..}
      reader = readerWith environment
      writer = writerWith environment

  scottyApp $ do
-------------------------------- Create Account --------------------------------
    let createAccount ∷ Text → Text → ActionM CreateAccountResult
        createAccount username password =
          assert ((username /= "") && (password /= "")) ∘ liftIO
          $
          catch
            (do
              logIO $ [i|Request to create an account for "#{username}" with password "#{password}"|]
              logIO "MOTA A"
              new_account ← newAccount password
              logIO "MADE IT HERE!!!"
              logIO $ "MOTA B: " ⊕ show new_account
              result ← atomically $ do
                unsafeIOToSTM (logIO "ATOM A")
                accounts ← readTVar accounts_tvar
                unsafeIOToSTM (logIO "ATOM B")
                let mem = member username accounts
                unsafeIOToSTM (logIO "ATOM C")
                if trace ("member =" ⊕ show mem) mem
                  then do
                    unsafeIOToSTM (logIO "ATOM D1")
                    return AccountExists
                  else do
                    unsafeIOToSTM (logIO "ATOM D2")
                    account_tvar ← newTVar new_account
                    unsafeIOToSTM (logIO "ATOM E2")
                    modifyTVar accounts_tvar $ insertMap username account_tvar
                    unsafeIOToSTM (logIO "ATOM F2")
                    return AccountCreated
              logIO "MOTA C"
              pure result
            )
            (\(e ∷ SomeException) → logIO [i|EXC: #{e}|] >> throwIO e)

    Scotty.post "/api/create" $
      (do
        logRequest
        logIO "API A"
        username ← param "username"
        password ← param "password"
        logIO "API B"
        account_status ← createAccount username password
        logIO "API C"
        case account_status of
          AccountExists → do
            logIO $ [i|Account "#{username}" already exists!|]
            finishWithStatus conflict409
          AccountCreated → do
            logIO $ [i|Account "#{username}" successfully created!|]
            status created201
            Scotty.text ∘ view (from strict) ∘ encodeSigned HS256 password_secret $ def
              { iss = Just expected_iss
              , sub = Just (fromJust $ stringOrURI username)
              }
        logIO "API D"
       `rescue` (liftIO ∘ logIO ∘ show)
      )

    let returnCreateAccountForm ∷ Text → Text → ActionM ()
        returnCreateAccountForm username error_message = do
          Scotty.html ∘ renderHtml ∘ docTypeHtml $ do
            head $ title "Create account"
            body ∘ (form ! action "/create" ! method "post") ∘ foldMap div $
             [ table ∘ (foldMap $ tr ∘ foldMap td) $
               [ [ p $ "Username:"
                 , input ! name "username" ! type_ "text" ! value (toValue username)
                 ]
               , [ p $ "Password:", input ! type_ "password" ! name "password"]
               , [ p $ "Password (again):", input ! type_ "password" ! name "password2"]
               ]
             , button ! id "create-account" $ "Create account"
             , p ! id "error-message" $ toHtml error_message
             ]
          finish

    Scotty.get "/create" $ returnCreateAccountForm "" ""

    Scotty.post "/create" $
     (do
      logIO "Web A"
      username ← paramOrBlank "username"
      when (username == "") $
        returnCreateAccountForm username no_username_message
      logIO "Web B"
      password ← paramOrBlank "password"
      when (password == "") $
        returnCreateAccountForm username no_password_message
      logIO "Web C"
      password2 ← paramOrBlank "password2"
      when (password2 == "") $
        returnCreateAccountForm username no_password2_message
      when (password /= password2) $
        returnCreateAccountForm username password_mismatch_message
      logIO "Web D"
      createAccount username password >>=
        \case
          AccountExists → do
            logIO $ [i|Account "#{username}" already exists!|]
            status ok200
            returnCreateAccountForm username account_exists_message
          AccountCreated → do
            logIO $ [i|Account "#{username}" successfully created!|]
            status created201
            Scotty.html ∘ renderHtml ∘ docTypeHtml ∘ body $ "Account created!"
      logIO "Web E"
      `rescue` (liftIO ∘ logIO ∘ show)
     )
------------------------------------ Login -------------------------------------
    Scotty.post "/api/login" $ do
      logRequest
      username ← param "username"
      password ← param "password"
      logIO $ [i|Request to log into an account with "#{username}" with password "#{password}"|]
      (
        (fmap (lookup username) ∘ liftIO ∘ readTVarIO $ accounts_tvar)
        >>=
        maybe (finishWithStatusMessage 404 "Not Found: No such account") return
        >>=
        liftIO ∘ readTVarIO
        >>=
        bool (finishWithStatusMessage 403 "Forbidden: Invalid password") (logIO "Login successful.")
        ∘
        passwordIsValid password
       )
      Scotty.text ∘ view (from strict) ∘ encodeSigned HS256 password_secret $ def
        { iss = Just expected_iss
        , sub = Just (fromJust $ stringOrURI username)
        }
-------------------------------- Get All Habits --------------------------------
    Scotty.get "/api/habits" ∘ reader $ do
      log "Requested all habits."
      view habits >>= returnJSON ok200
---------------------------------- Get Habit -----------------------------------
    Scotty.get "/api/habits/:habit_id" ∘ reader $ do
      habit_id ← getParam "habit_id"
      log $ [i|Requested habit with id #{habit_id}.|]
      habits_ ← view habits
      case lookup habit_id habits_ of
        Nothing → raiseNoSuchHabit
        Just habit → returnJSON ok200 habit
--------------------------------- Delete Habit ---------------------------------
    Scotty.delete "/api/habits/:habit_id" ∘ writer $ do
      habit_id ← getParam "habit_id"
      log $ [i|Requested to delete habit with id #{habit_id}.|]
      habit_was_there ← isJust <$> (habits . at habit_id <<.= Nothing)
      returnNothing $
        if habit_was_there
          then noContent204
          else notFound404
---------------------------------- Put Habit -----------------------------------
    Scotty.put "/api/habits/:habit_id" ∘ writer $ do
      habit_id ← getParam "habit_id"
      log $ [i|Requested to put habit with id #{habit_id}.|]
      habit ← getBodyJSON
      habit_was_there ← isJust <$> (habits . at habit_id <<.= Just habit)
      returnNothing $
        if habit_was_there
          then noContent204
          else created201
--------------------------------- Get Credits ----------------------------------
    Scotty.get "/api/credits" ∘ reader $ do
      log $ "Requested credits."
      view (game . credits) >>= returnJSON ok200
--------------------------------- Mark Habits ----------------------------------
    Scotty.post "/api/mark" ∘ writer $ do
      let markHabits ∷ [UUID] → Lens' Credits Double → WriterProgram Double
          markHabits uuids which_credits = do
            habits ← mapM lookupHabit uuids
            new_credits ←
              (+ sum (map (view $ credits . which_credits) habits))
              <$>
              use (game . credits . which_credits)
            game . credits . which_credits .= new_credits
            return new_credits
      marks ← getBodyJSON
      log $ [i|Marked #{marks ^. successes} successes and #{marks ^. failures} failures.|]
      (Credits
          <$> markHabits (marks ^. successes) success
          <*> markHabits (marks ^. failures ) failure
       ) >>= returnJSON ok200
----------------------------------- Run Game -----------------------------------
    Scotty.post "/api/run" ∘ writer $ do
      let go d = do
            let r = runAccount d
            l_ #quest_events %= (|> r ^. story . to createEvent)
            if stillHasCredits (r ^. new_data)
              then do
                when (r ^. quest_completed) $
                  (l_ #quest_events <<.= mempty)
                  >>=
                  (l_ #quests %=) ∘ flip (|>) ∘ createQuest
                go (r ^. new_data)
              else return (r ^. new_data)
      (new_d, s) ←
        get
        >>=
        flip runStateT
          ( #quests := (mempty ∷ Seq Quest)
          , #quest_events := (mempty ∷ Seq Event)
          )
        ∘
        go
      put new_d
      returnLazyText ok200 $!! (
        renderStoryToText
        ∘
        createStory
        $
        s ^. l_ #quests |> s ^. l_ #quest_events . to createQuest
        )
---------------------------------- Not Found -----------------------------------
    Scotty.notFound $ do
      r ← Scotty.request
      logIO $ [i|URL not found! #{requestMethod r} #{rawPathInfo r}#{rawQueryString r}|]
      Scotty.next

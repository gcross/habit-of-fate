{-
    Habit of Fate, a game to incentivize habit formation.
    Copyright (C) 2017 Gregory Crosswhite

    This program is free software: you can redistribute it and/or modify
    it under version 3 of the terms of the GNU Affero General Public License.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
-}

{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ParallelListComp #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE UnicodeSyntax #-}
{-# LANGUAGE ViewPatterns #-}

module HabitOfFate.Server
  ( Username(..)
  , makeApp
  , makeAppRunningInTestMode
  ) where

import HabitOfFate.Prelude hiding (div, id, log)

import Data.Aeson hiding ((.=))
import Control.Concurrent
import Control.Concurrent.STM
import Control.DeepSeq
import Control.Monad.Random
import Control.Monad.Operational (Program, interpretWithMonad)
import qualified Control.Monad.Operational as Operational
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LazyBS
import Data.List (zipWith)
import Data.Set (minView)
import qualified Data.String as String
import qualified Data.Text.Lazy as Lazy
import Data.Time.Clock
import Data.UUID hiding (null)
import GHC.Conc.Sync (unsafeIOToSTM)
import Network.HTTP.Types.Status
import Network.Wai
import System.IO (BufferMode(LineBuffering), hSetBuffering, stderr)
import Text.Blaze.Html.Renderer.Text (renderHtml)
import Text.Blaze.Html5 (Html, (!), toHtml)
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A
import Text.Cassius (Css, cassius, renderCss)
import Text.XML
import Web.Cookie
import Web.Scotty
  ( ActionM
  , Param
  , Parsable
  , addHeader
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
import HabitOfFate.Habit
import HabitOfFate.Logging
import HabitOfFate.Story
import HabitOfFate.Story.Renderer.HTML
import HabitOfFate.Story.Renderer.XML

import Paths_habit_of_fate (getDataFileName)

--------------------------------------------------------------------------------
-------------------------------- Miscellaneous ---------------------------------
--------------------------------------------------------------------------------

instance Parsable UUID where
  parseParam = view strict >>> fromText >>> maybe (Left "badly formed UUID") Right

newtype Username = Username { unwrapUsername ∷ Text } deriving
  ( Eq
  , FromJSONKey
  , Ord
  , Parsable
  , Read
  , Show
  , ToJSONKey
  )

instance FromJSON Username where
  parseJSON = parseJSON >>> fmap Username

instance ToJSON Username where
  toJSON = unwrapUsername >>> toJSON
  toEncoding = unwrapUsername >>> toEncoding

newtype Cookie = Cookie Text deriving (Eq,FromJSON,Ord,Parsable,Read,Show,ToJSON)

data Environment = Environment
  { accounts_tvar ∷ TVar (Map Username (TVar Account))
  , cookies_tvar ∷ TVar (Map Cookie (UTCTime, Username))
  , expirations_tvar ∷ TVar (Set (UTCTime, Cookie))
  , write_request_var ∷ TMVar ()
  }

readTVarMonadIO ∷ MonadIO m ⇒ TVar α → m α
readTVarMonadIO = readTVarIO >>> liftIO

addCSS ∷ String → ((() → Text) → Css) → Scotty.ScottyM ()
addCSS name contents = Scotty.get (String.fromString $ "/css/" ⊕ name ⊕ ".css") $ do
  addHeader "Content-Type" "text/css"
  contents |> ($ (\() → "")) |> renderCss |> Scotty.text

--------------------------------------------------------------------------------
---------------------------- Shared Scotty Actions -----------------------------
--------------------------------------------------------------------------------

----------------------------------- Queries ------------------------------------

lookupHabit ∷ (ActionMonad m, MonadState Account m) ⇒ UUID → m Habit
lookupHabit habit_id = do
  use (habits_ . at habit_id)
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
paramOrBlank name = Scotty.param name `rescue` ("" |> pure |> const)

bodyJSON ∷ FromJSON α ⇒ ActionM α
bodyJSON = do
  body_ ← Scotty.body
  case eitherDecode' body_ of
    Left message → do
      logIO [i|Error parsing JSON for reason "#{message}#:\n#{decodeUtf8 body_}|]
      finishWithStatusMessage 400 "Bad request: Invalid JSON"
    Right value → pure value

authorizeWith ∷ (∀ α. String → ActionM α) → Environment → ActionM (Username, TVar Account)
authorizeWith actionWhenAuthFails Environment{..} = do
  let handleForbidden ∷ String → Maybe α → ActionM α
      handleForbidden message = maybe (actionWhenAuthFails message) pure
  cookie_header ← Scotty.header "Cookie" >>= handleForbidden "No cookie header."
  cookie ∷ Cookie ←
    cookie_header
      |> view strict
      |> encodeUtf8
      |> parseCookiesText
      |> lookup "token"
      |> handleForbidden "No authorization token in the cookies."
      |> fmap Cookie
  current_time ← liftIO getCurrentTime
  (liftIO <<< atomically <<< runExceptT $ do
    cookies ← lift $ readTVar cookies_tvar
    (expiration_time, username) ←
      cookies
        |> lookup cookie
        |> maybe (throwError "Authorization token unrecognized.") pure
    (expiration_time, cookie)
        |> deleteSet
        |> modifyTVar expirations_tvar
        |> lift
    when (expiration_time < current_time) $ throwError "Authorization token expired."
    accounts ← lift $ readTVar accounts_tvar
    account_tvar ←
      accounts
      |> lookup username
      |> maybe
          (do lift $ modifyTVar cookies_tvar (deleteMap cookie)
              throwError "Token no longer refers to an existing user."
          )
          pure
    lift $ do
      let new_expected_time = addUTCTime (30*86400) current_time
      modifyTVar cookies_tvar $ insertMap cookie (new_expected_time, username)
      modifyTVar expirations_tvar $ insertSet (new_expected_time, cookie)
    pure (username, account_tvar)
   ) >>= either actionWhenAuthFails pure

----------------------------------- Results ------------------------------------

finishWithStatus ∷ Status → ActionM α
finishWithStatus s = do
  logIO $ "Finished with status: " ⊕ show s
  status s
  finish

finishWithStatusMessage ∷ Int → String → ActionM α
finishWithStatusMessage code = pack >>> encodeUtf8 >>> Status code >>> finishWithStatus

valueOrRedirectToLogin ∷ Maybe α → ActionM α
valueOrRedirectToLogin = maybe (Scotty.redirect "/login") pure

setContent ∷ Content → ActionM ()
setContent NoContent = pure ()
setContent (TextContent t) = Scotty.text t
setContent (TextContentAsHTML t) = Scotty.html t
setContent (HtmlContent h) = h |> toHtml |> renderHtml |> Scotty.html
setContent (JSONContent j) = Scotty.json j

setStatusAndLog ∷ Status → ActionM ()
setStatusAndLog status_@(Status code message) = do
  status status_
  let result
        | code < 200 || code >= 300 = "failed"
        | otherwise = "succeeded"
  logIO $ [i|Request #{result} - #{code} #{decodeUtf8 >>> unpack $ message}|]

data ProgramResult = ProgramRedirectsTo Lazy.Text | ProgramResult Status Content

data Content =
    NoContent
  | TextContent Lazy.Text
  | TextContentAsHTML Lazy.Text
  | HtmlContent Html
  | ∀ α. ToJSON α ⇒ JSONContent α

returnNothing ∷ Monad m ⇒ Status → m ProgramResult
returnNothing s = return $ ProgramResult s NoContent

returnLazyText ∷ Monad m ⇒ Status → Lazy.Text → m ProgramResult
returnLazyText s = TextContent >>> ProgramResult s >>> return

returnLazyTextAsHTML ∷ Monad m ⇒ Status → Lazy.Text → m ProgramResult
returnLazyTextAsHTML s = TextContentAsHTML >>> ProgramResult s >>> return

returnText ∷ Monad m ⇒ Status → Text → m ProgramResult
returnText s = view (from strict) >>> returnLazyText s

returnJSON ∷ (ToJSON α, Monad m) ⇒ Status → α → m ProgramResult
returnJSON s = JSONContent >>> ProgramResult s >>> return

redirectTo ∷ Monad m ⇒ Lazy.Text → m ProgramResult
redirectTo = ProgramRedirectsTo >>> return

renderHTMLUsingTemplate ∷ Text → [Text] → Html → Lazy.Text
renderHTMLUsingTemplate title stylesheets body =
  renderHtml $
    H.docTypeHtml $ do
      H.head $
        (H.title $ toHtml title)
        ⊕
        mconcat
          [ H.link
              ! A.rel "stylesheet"
              ! A.type_ "text/css"
              ! A.href (H.toValue $ mconcat ["css/", stylesheet, ".css"])
          | stylesheet ← stylesheets
          ]
      H.body body

renderHTMLUsingTemplateAndReturn ∷ Monad m ⇒ Text → [Text] → Status → Html → m ProgramResult
renderHTMLUsingTemplateAndReturn title stylesheets status =
  renderHTMLUsingTemplate title stylesheets
  >>>
  returnLazyTextAsHTML status

renderEventToHTMLAndReturn title stylesheets status =
  renderEventToHTML
  >>>
  renderHTMLUsingTemplateAndReturn title stylesheets status

logRequest ∷ ActionM ()
logRequest = do
  r ← Scotty.request
  logIO $ [i|URL requested: #{requestMethod r} #{rawPathInfo r}#{rawQueryString r}|]

--------------------------------------------------------------------------------
--------------------------------- Action Monad ---------------------------------
--------------------------------------------------------------------------------

------------------------------------ Common ------------------------------------

data CommonInstruction α where
  GetBodyInstruction ∷ CommonInstruction LazyBS.ByteString
  GetParamsInstruction ∷ CommonInstruction [Param]
  RaiseStatusInstruction ∷ Status → CommonInstruction α
  LogInstruction ∷ String → CommonInstruction ()

class Monad m ⇒ ActionMonad m where
  singletonCommon ∷ CommonInstruction α → m α

getBody ∷ ActionMonad m ⇒ m LazyBS.ByteString
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

getParamMaybe ∷ (Parsable α, ActionMonad m) ⇒ Lazy.Text → m (Maybe α)
getParamMaybe param_name =
  getParams
  <&>
  (lookup param_name >=> (parseParam >>> either (const Nothing) return))

paramMaybe ∷ Parsable α ⇒ Lazy.Text → ActionM (Maybe α)
paramMaybe param_name = (param param_name <&> Just) `rescue` (const $ pure Nothing)

raiseStatus ∷ ActionMonad m ⇒ Int → String → m α
raiseStatus code =
  pack
  >>>
  encodeUtf8
  >>>
  Status code
  >>>
  RaiseStatusInstruction
  >>>
  singletonCommon

raiseNoSuchHabit = raiseStatus 404 "Not found: No such habit"

log ∷ ActionMonad m ⇒ String → m ()
log = LogInstruction >>> singletonCommon

------------------------------------ Reader ------------------------------------

data ReaderInstruction α where
  ReaderCommonInstruction ∷ CommonInstruction α → ReaderInstruction α
  ReaderViewInstruction ∷ ReaderInstruction Account

newtype ReaderProgram α = ReaderProgram
  { unwrapReaderProgram ∷ Program ReaderInstruction α }
  deriving (Applicative, Functor, Monad)

instance ActionMonad ReaderProgram where
  singletonCommon = ReaderCommonInstruction >>> Operational.singleton >>> ReaderProgram

instance MonadReader Account (ReaderProgram) where
  ask = ReaderProgram $ Operational.singleton ReaderViewInstruction
  local = error "if you see this, then ReaderProgram needs to have a local method"

readerWith ∷ (∀ α. String → ActionM α) → Environment → ReaderProgram ProgramResult → ActionM ()
readerWith actionWhenAuthFails environment (ReaderProgram program) = do
  logRequest
  (username, account_tvar) ← authorizeWith actionWhenAuthFails environment
  params_ ← params
  body_ ← Scotty.body
  account ← account_tvar |> readTVarMonadIO
  let interpret ∷ ReaderInstruction α → ExceptT Status (Writer (Seq String)) α
      interpret (ReaderCommonInstruction GetBodyInstruction) = pure body_
      interpret (ReaderCommonInstruction GetParamsInstruction) = pure params_
      interpret (ReaderCommonInstruction (RaiseStatusInstruction s)) = throwError s
      interpret (ReaderCommonInstruction (LogInstruction message)) =
        void ([i|[#{unwrapUsername username}]: #{message}|] |> singleton |> tell)
      interpret ReaderViewInstruction = pure account
      (error_or_result, logs) =
        program
          |> interpretWithMonad interpret
          |> runExceptT
          |> runWriter
  traverse_ logIO logs
  case error_or_result of
    Left status_ →
      setStatusAndLog status_
    Right (ProgramRedirectsTo href) → Scotty.redirect href
    Right (ProgramResult status_ content) → do
      setStatusAndLog status_
      setContent content

------------------------------------ Writer ------------------------------------

data WriterInstruction α where
  WriterCommonInstruction ∷ CommonInstruction α → WriterInstruction α
  WriterGetAccountInstruction ∷ WriterInstruction Account
  WriterPutAccountInstruction ∷ Account → WriterInstruction ()

newtype WriterProgram α = WriterProgram
  { unwrapWriterProgram ∷ Program WriterInstruction α }
  deriving (Applicative, Functor, Monad)

instance ActionMonad WriterProgram where
  singletonCommon = WriterCommonInstruction >>> Operational.singleton >>> WriterProgram

instance MonadState Account WriterProgram where
  get = Operational.singleton WriterGetAccountInstruction |> WriterProgram
  put = WriterPutAccountInstruction >>> Operational.singleton >>> WriterProgram

writerWith ∷ (∀ α. String → ActionM α) → Environment → WriterProgram ProgramResult → ActionM ()
writerWith actionWhenAuthFails (environment@Environment{..}) (WriterProgram program) = do
  logRequest
  (username, account_tvar) ← authorizeWith actionWhenAuthFails environment
  params_ ← params
  body_ ← Scotty.body
  let interpret ∷
        WriterInstruction α →
        StateT Account (ExceptT Status (RandT StdGen (Writer (Seq String)))) α
      interpret (WriterCommonInstruction GetBodyInstruction) = pure body_
      interpret (WriterCommonInstruction GetParamsInstruction) = pure params_
      interpret (WriterCommonInstruction (RaiseStatusInstruction s)) = throwError s
      interpret (WriterCommonInstruction (LogInstruction message)) =
        void ([i|[#{unwrapUsername username}]: #{message}|] |> singleton |> tell)
      interpret WriterGetAccountInstruction = get
      interpret (WriterPutAccountInstruction new_account) = put new_account
  initial_generator ← liftIO newStdGen
  (redirect_or_content, logs) ← atomically >>> liftIO $ do
    old_account ← readTVar account_tvar
    let (error_or_result, logs) =
          interpretWithMonad interpret program
            |> flip runStateT old_account
            |> runExceptT
            |> flip evalRandT initial_generator
            |> runWriter
    case error_or_result of
      Left status_ → pure (Right (status_, Nothing), logs)
      Right (result, new_account) → do
        writeTVar account_tvar new_account
        tryPutTMVar write_request_var ()
        pure $ case result of
          ProgramRedirectsTo href → (Left href, logs)
          ProgramResult status_ content → (Right (status_, Just content), logs)
  traverse_ logIO logs
  case redirect_or_content of
    Left href → Scotty.redirect href
    Right (status_, maybe_content) → do
      setStatusAndLog status_
      maybe (pure ()) setContent maybe_content

------------------------------------ Shared ------------------------------------

runEvent = do
  account ← get
  let (event, new_account) = runState runAccount account
  put new_account
  pure event

--------------------------------------------------------------------------------
------------------------------ Server Application ------------------------------
--------------------------------------------------------------------------------

data RunGameState = RunGameState
  { _run_quests_ ∷ Seq [Event]
  , _run_quest_events_ ∷ Seq Event
  }
makeLenses ''RunGameState

makeAppWithTestMode ∷
  Bool →
  Map Username Account →
  (Map Username Account → IO ()) →
  IO Application
makeAppWithTestMode test_mode initial_accounts saveAccounts = do
  liftIO $ hSetBuffering stderr LineBuffering

  logIO $ "Starting server..."

  accounts_tvar ← atomically $
    traverse newTVar initial_accounts >>= newTVar

  cookies_tvar ← newTVarIO mempty
  expirations_tvar ← newTVarIO mempty

  forkIO <<< forever $
    let go =
          (
            atomically $ do
              current_time ← unsafeIOToSTM getCurrentTime
              expirations ← readTVar expirations_tvar
              case minView expirations of
                Nothing → pure False
                Just (first@(first_time, first_cookie), rest) → do
                  if first_time < current_time
                    then do
                      unsafeIOToSTM $ logIO [i|Dropping cookie #{first} at #{current_time}.|]
                      modifyTVar cookies_tvar $ deleteMap first_cookie
                      writeTVar expirations_tvar rest
                      pure True
                    else
                      pure False
          )
          >>=
          \case { False → threadDelay (60 * 1000 * 1000) >> go; _ → go }
    in go

  let createAndReturnCookie ∷ Username → ActionM ()
      createAndReturnCookie username = do
        Cookie token ← liftIO $ do
          current_time ← getCurrentTime
          cookie ← (pack >>> Cookie) <$> (replicateM 20 $ randomRIO ('A','z'))
          atomically $ do
            let expiration_time = addUTCTime (30*86400) current_time
            modifyTVar cookies_tvar $ insertMap cookie (expiration_time, username)
            modifyTVar expirations_tvar $ insertSet (expiration_time, cookie)
          pure cookie
        def
          { setCookieName="token"
          , setCookieValue=encodeUtf8 token
          , setCookieHttpOnly=True
          , setCookieSameSite=Just sameSiteStrict
          , setCookieSecure=not test_mode
          }
          |> renderSetCookie
          |> Builder.toLazyByteString
          |> decodeUtf8
          |> Scotty.setHeader "Set-Cookie"

  write_request_var ← newEmptyTMVarIO
  forever >>> forkIO $
    (atomically $ do
      takeTMVar write_request_var
      readTVar accounts_tvar >>= traverse readTVar
    )
    >>=
    saveAccounts

  let environment = Environment{..}
      apiReader = readerWith (finishWithStatusMessage 403) environment
      apiWriter = writerWith (finishWithStatusMessage 403) environment
      wwwReader = readerWith (const $ Scotty.redirect "/login") environment
      wwwWriter = writerWith (const $ Scotty.redirect "/login") environment

  scottyApp $ do
-------------------------------- Create Account --------------------------------
    Scotty.post "/api/create" $ do
      logRequest
      username ← param "username"
      password ← param "password"
      logIO $ [i|Request to create an account for "#{username}".|]
      liftIO >>> join $ do
        new_account ← newAccount password
        atomically $ do
          accounts ← readTVar accounts_tvar
          if member username accounts
            then pure $ do
              logIO $ [i|Account "#{username}" already exists!|]
              status conflict409
            else do
              account_tvar ← newTVar new_account
              modifyTVar accounts_tvar $ insertMap username account_tvar
              pure $ do
                logIO $ [i|Account "#{username}" successfully created!|]
                status created201
                createAndReturnCookie username
    let basicTextInput type_ name placeholder =
          (! A.type_ type_)
          >>>
          (! A.name name)
          >>>
          (! A.placeholder placeholder)
        basicTextForm =
          foldMap
            (\setAttributes →
              H.input |> setAttributes |> (H.div ! A.class_ "fields")
            )
        createAccountAction = do
          logRequest
          username@(Username username_) ← Username <$> paramOrBlank "username"
          password1 ← paramOrBlank "password1"
          password2 ← paramOrBlank "password2"
          error_message ∷ Text ←
            if ((not . onull $ password1) && password1 == password2)
              then do
                logIO $ [i|Request to create an account for "#{username_}".|]
                liftIO >>> join $ do
                  new_account ← newAccount password1
                  atomically $ do
                    accounts ← readTVar accounts_tvar
                    if member username accounts
                      then pure $ do
                        logIO $ [i|Account "#{username_}" already exists!|]
                        status conflict409
                        pure "This account already exists."
                      else do
                        account_tvar ← newTVar new_account
                        modifyTVar accounts_tvar $ insertMap username account_tvar
                        pure $ do
                          logIO $ [i|Account "#{username_}" successfully created!|]
                          createAndReturnCookie username
                          Scotty.redirect "/"
              else pure $
                if onull username_
                  then
                    if onull password1
                      then ""
                      else "Did not specify username."
                  else
                    case (password1, password2) of
                      ("", "") → "Did not type the password."
                      ("", _) → "Did not type the password twice."
                      (_, "") → "Did not type the password twice."
                      _ | password1 == password2 → ""
                      _ | otherwise → "The passwords did not agree."
          renderHTMLUsingTemplate "Habit of Fate - Account Creation" ["common", "enter"] >>> Scotty.html $
            H.div ! A.class_ "enter" $ do
              H.div ! A.class_ "tabs" $ do
                H.span ! A.class_ "inactive" $ H.a ! A.href "/login" $ H.toHtml ("Login" ∷ Text)
                H.span ! A.class_ "active" $ H.toHtml ("Create" ∷ Text)
              H.form ! A.method "post" $ do
                basicTextForm >>> H.div $
                  [ basicTextInput "text" "username" "Username" >>> (! A.value (H.toValue username_))
                  , basicTextInput "password" "password1" "Password"
                  , basicTextInput "password" "password2" "Password (again)"
                  ]
                when ((not <<< onull) error_message) $
                  H.div ! A.id "error-message" $ H.toHtml error_message
                H.div $
                  H.input
                    ! A.class_ "submit"
                    ! A.type_ "submit"
                    ! A.formmethod "post"
                    ! A.value "Create Account"
    Scotty.get "/create" $ createAccountAction
    Scotty.post "/create" $ createAccountAction
------------------------------------ Login -------------------------------------
    Scotty.post "/api/login" $ do
      logRequest
      username ← param "username"
      password ← param "password"
      logIO $ [i|Request to log into an account with "#{username}".|]
      account_tvar ←
        (accounts_tvar |> readTVarMonadIO |> fmap (lookup username))
        >>=
        maybe (finishWithStatusMessage 404 "Not Found: No such account") return
      (
        readTVarMonadIO account_tvar
        >>=
        (
          passwordIsValid password
          >>>
          bool (finishWithStatusMessage 403 "Forbidden: Invalid password") (logIO "Login successful.")
        )
        >>
        createAndReturnCookie username
       )
    let loginAction = do
          logRequest
          username@(Username username_) ← Username <$> paramOrBlank "username"
          password ← paramOrBlank "password"
          error_message ∷ Text ←
            if onull username_
              then pure ""
              else do
                logIO [i|Request to log in "#{username_}".|]
                accounts ← readTVarMonadIO accounts_tvar
                case lookup username accounts of
                  Nothing → do
                    logIO [i|No account has username #{username_}.|]
                    pure "No account has that username."
                  Just account_tvar → do
                    account ← readTVarMonadIO account_tvar
                    if passwordIsValid password account
                      then do
                        logIO [i|Successfully logged in #{username_}.|]
                        createAndReturnCookie username
                        Scotty.redirect "/habits"
                      else do
                        logIO [i|Incorrect password for #{username_}.|]
                        pure "No account has that username."
          renderHTMLUsingTemplate "Habit of Fate - Login" ["common", "enter"] >>> Scotty.html $
            H.div ! A.class_ "enter" $ do
              H.div ! A.class_ "tabs" $ do
                H.span ! A.class_ "active" $ H.toHtml ("Login" ∷ Text)
                H.span ! A.class_ "inactive" $ H.a ! A.href "/create" $ H.toHtml ("Create" ∷ Text)
              H.form ! A.method "post" $ do
                basicTextForm >>> H.div $
                  [ basicTextInput "text" "username" "Username" >>> (! A.value (H.toValue username_))
                  , basicTextInput "password" "password" "Password"
                  ]
                when ((not <<< onull) error_message) $
                  H.div ! A.id "error-message" $ H.toHtml error_message
                H.div $
                  H.input
                    ! A.class_ "submit"
                    ! A.type_ "submit"
                    ! A.formmethod "post"
                    ! A.value "Login"
    Scotty.get "/login" loginAction
    Scotty.post "/login" loginAction
------------------------------------ Logout ------------------------------------
    let logoutAction = do
          logRequest
          maybe_cookie_header ← Scotty.header "Cookie"
          case maybe_cookie_header of
            Nothing → pure ()
            Just cookie_header →
              let maybe_cookie =
                    cookie_header
                      |> view strict
                      |> encodeUtf8
                      |> parseCookiesText
                      |> lookup "token"
                      |> fmap Cookie
              in case maybe_cookie of
                Nothing → pure ()
                Just cookie → (liftIO <<< atomically) $ do
                  cookies ← readTVar cookies_tvar
                  case lookup cookie cookies of
                    Nothing → pure ()
                    Just (expiration_time, _) →
                      modifyTVar expirations_tvar $ deleteSet (expiration_time, cookie)
                  writeTVar cookies_tvar $ deleteMap cookie cookies
    Scotty.post "/api/logout" logoutAction
    Scotty.post "/logout" $ logoutAction >> Scotty.redirect "/login"
-------------------------------- Get All Habits --------------------------------
    Scotty.get "/api/habits" <<< apiReader $ do
      log "Requested all habits."
      view habits_ >>= returnJSON ok200
    Scotty.get "/habits/new" $
      liftIO (randomIO ∷ IO UUID) <&> (show >>> Lazy.pack >>> ("/habits/" ⊕))
      >>=
      Scotty.redirect
    Scotty.get "/habits" <<< wwwReader $ do
      habit_list ← view (habits_ . habit_list_)
      renderHTMLUsingTemplateAndReturn "Habit of Fate - List of Habits" ["common", "list"] ok200 $
        H.div ! A.class_ "list" $ do
          H.table $ do
            H.thead $ foldMap (H.toHtml >>> H.th) [""∷Text, "#", "Name", "Difficulty", "Importance", "Success", "Failure"]
            H.tbody <<< mconcat $
              [ H.tr ! A.class_ ("row " ⊕ if n `mod` 2 == 0 then "even" else "odd") $ do
                  H.td $ H.form ! A.method "post" ! A.action (H.toValue $ "/move/" ⊕ show uuid) $ do
                    H.input
                      ! A.type_ "submit"
                      ! A.value "Move To"
                    H.input
                      ! A.type_ "text"
                      ! A.value (H.toValue n)
                      ! A.name "new_index"
                      ! A.class_ "new-index"
                  H.td $ H.toHtml (show n ⊕ ".")
                  H.td ! A.class_ "name" $
                    H.a ! A.href (H.toValue ("/habits/" ⊕ pack (show uuid) ∷ Text)) $ H.toHtml (habit ^. name_)
                  let addScaleElement scale_class scale_lens =
                        H.td ! A.class_ scale_class $ H.toHtml $ displayScale $ habit ^. scale_lens
                  addScaleElement "difficulty" difficulty_
                  addScaleElement "importance" importance_
                  let addMarkElement name label =
                        H.td $
                          H.form ! A.method "post" ! A.action (H.toValue $ "/mark/" ⊕ name ⊕ "/" ⊕ show uuid) $
                            H.input ! A.type_ "submit" ! A.value label
                  addMarkElement "success" "😃"
                  addMarkElement "failure" "😞"
              | n ← [1∷Int ..]
              | (uuid, habit) ← habit_list
              ]
          H.a ! A.href "/habits/new" $ H.toHtml ("New" ∷ Text)
---------------------------------- Move Habit ----------------------------------
    let move = wwwWriter $ do
          habit_id ← getParam "habit_id"
          new_index ← getParam "new_index" <&> (\n → n-1)
          log [i|Web POST request to move habit with id #{habit_id} to index #{new_index}.|]
          old_habits ← use habits_
          case moveHabitWithIdToIndex habit_id new_index old_habits of
            Left exc → log [i|Exception moving habit: #{exc}|]
            Right new_habits → habits_ .= new_habits
          redirectTo "/"
    Scotty.post "/move/:habit_id" move
    Scotty.post "/move/:habit_id/:new_index" move
---------------------------------- Get Habit -----------------------------------
    let habitPage ∷ Monad m ⇒ UUID → Lazy.Text → Lazy.Text → Lazy.Text → Habit → m ProgramResult
        habitPage habit_id name_error difficulty_error importance_error habit =
          renderHTMLUsingTemplate "Habit of Fate - Editing a Habit" [] >>> returnLazyTextAsHTML ok200 $
            H.form ! A.method "post" $ do
              H.div $ H.table $ do
                H.tr $ do
                  H.td $ H.toHtml ("Name:" ∷ Text)
                  H.td $ H.input ! A.type_ "text" ! A.name "name" ! A.value (H.toValue $ habit ^. name_)
                  H.td $ H.toHtml name_error
                let generateScaleEntry name value_lens =
                      H.select ! A.name name ! A.required "true" $
                        flip foldMap scales $ \scale →
                          let addSelectedFlag
                                | habit ^. value_lens == scale = (! A.selected "selected")
                                | otherwise = identity
                              unselected_option = H.option ! A.value (scale |> show |> H.toValue)
                          in addSelectedFlag unselected_option $ H.toHtml (displayScale scale)
                H.tr $ do
                  H.td $ H.toHtml ("Difficulty:" ∷ Text)
                  H.td $ generateScaleEntry "difficulty" difficulty_
                  H.td $ H.toHtml difficulty_error
                H.tr $ do
                  H.td $ H.toHtml ("Importance:" ∷ Text)
                  H.td $ generateScaleEntry "importance" importance_
                  H.td $ H.toHtml importance_error
              H.div $ do
                H.input !  A.type_ "submit"
                H.a ! A.href "/habits" $ toHtml ("Cancel" ∷ Text)
    Scotty.get "/api/habits/:habit_id" <<< apiReader $ do
      habit_id ← getParam "habit_id"
      log $ [i|Requested habit with id #{habit_id}.|]
      (view $ habits_ . at habit_id)
        >>= maybe raiseNoSuchHabit (returnJSON ok200)

    Scotty.get "/habits/:habit_id" <<< wwwReader $ do
      habit_id ← getParam "habit_id"
      log $ [i|Web GET request for habit with id #{habit_id}.|]
      (view (habits_ . at habit_id) <&> fromMaybe def)
        >>= habitPage habit_id "" "" ""

    Scotty.post "/habits/:habit_id" <<< wwwWriter $ do
      habit_id ← getParam "habit_id"
      log $ [i|Web POST request for habit with id #{habit_id}.|]
      (unparsed_name, maybe_name, name_error) ← getParamMaybe "name" <&> \case
            Nothing → ("", Nothing, "No value for the name was present.")
            Just unparsed_name
              | onull unparsed_name → (unparsed_name, Nothing, "Name must not be blank.")
              | otherwise → (unparsed_name, Just (pack unparsed_name), "")
      let getScale param_name = getParamMaybe param_name <&> \case
            Nothing → ("", Nothing, "No value for the " ⊕ param_name ⊕ " was present.")
            Just unparsed_value →
              case readMaybe unparsed_value of
                Nothing → (unparsed_name, Nothing, "Invalid value for the " ⊕ param_name ⊕ ".")
                Just value → (unparsed_value, Just value, "")
      (unparsed_difficulty, maybe_difficulty, difficulty_error) ← getScale "difficulty"
      (unparsed_importance, maybe_importance, importance_error) ← getScale "importance"
      case Habit <$> maybe_name <*> (Difficulty <$> maybe_difficulty) <*> (Importance <$> maybe_importance) of
        Nothing → do
          log [i|Failed to update habit #{habit_id}:|]
          log [i|    Name error: #{name_error}|]
          log [i|    Difficulty error: #{difficulty_error}|]
          log [i|    Importance error: #{importance_error}|]
          habitPage habit_id name_error difficulty_error importance_error def
        Just new_habit → do
          log [i|Updating habit #{habit_id} to #{new_habit}|]
          habits_ . at habit_id <<.= Just new_habit
          redirectTo "/habits"
    Scotty.delete "/api/habits/:habit_id" <<< apiWriter $ do
      habit_id ← getParam "habit_id"
      log $ [i|Requested to delete habit with id #{habit_id}.|]
      habit_was_there ← isJust <$> (habits_ . at habit_id <<.= Nothing)
      returnNothing $
        if habit_was_there
          then noContent204
          else notFound404
---------------------------------- Put Habit -----------------------------------
    let apiWriteAction = do
          habit_id ← getParam "habit_id"
          log $ [i|Requested to put habit with id #{habit_id}.|]
          habit ← getBodyJSON
          habit_was_there ← isJust <$> (habits_ . at habit_id <<.= Just habit)
          returnNothing $
            if habit_was_there
              then noContent204
              else created201
    Scotty.post "/api/habits/:habit_id" <<< apiWriter $ apiWriteAction
    Scotty.put "/api/habits/:habit_id" <<< apiWriter $ apiWriteAction
--------------------------------- Get Credits ----------------------------------
    Scotty.get "/api/credits" <<< apiReader $ do
      log $ "Requested credits."
      view (stored_credits_) >>= returnJSON ok200
--------------------------------- Mark Habits ----------------------------------
    Scotty.post "/api/mark" <<< apiWriter $ do
      marks ← getBodyJSON
      let markHabits ∷
            Getter HabitsToMark [UUID] →
            Getter Habit Scale →
            Lens' Account Double →
            WriterProgram Double
          markHabits uuids_getter scale_getter value_lens = do
            old_value ← use value_lens
            increment ∷ Double ←
              marks
                |> (^. uuids_getter)
                |> mapM (lookupHabit >>> fmap ((^. scale_getter) >>> scaleFactor))
                |> fmap sum
            value_lens <.= old_value + increment
      log $ [i|Marking #{marks ^. succeeded} successes and #{marks ^. failed} failures.|]
      (Credits
          <$> (Successes <$> markHabits succeeded difficulty_ (stored_credits_ . successes_))
          <*> (Failures  <$> markHabits failed    importance_ (stored_credits_ . failures_ ))
       ) >>= returnJSON ok200
    let runGame = do
          event ← runEvent
          let rendered_event
                | (not <<< null) event = renderEventToHTML event
                | otherwise = H.p $ H.toHtml ("Nothing happened." ∷ Text)
          stored_credits ← use stored_credits_
          renderHTMLUsingTemplateAndReturn "Habit of Fate - Event" [] ok200 $ do
            rendered_event
            if stored_credits ^. successes_ /= 0 || stored_credits ^. failures_ /= 0
              then H.form ! A.method "post" $ H.input ! A.type_ "submit" ! A.value "Next"
              else H.a ! A.href "/habits" $ H.toHtml ("Done" ∷ Text)
        markHabit ∷
          String →
          Getter Habit Double →
          Lens' Credits Double →
          ActionM ()
        markHabit status habit_scale_getter_ credits_lens_ = wwwWriter $ do
          habits ← use habits_
          habit_id ← getParam "habit_id"
          log [i|Marking #{habit_id} as #{status}.|]
          case habits ^. at habit_id of
            Nothing →
              renderHTMLUsingTemplateAndReturn "Habit of Fate - Marking a Habit" [] notFound404 $ do
                H.h1 "Habit Not Found"
                H.p $ H.toHtml [i|"Habit #{habit_id} was not found.|]
            Just habit → do
              stored_credits_ . credits_lens_ += habit ^. habit_scale_getter_
              runGame
    Scotty.post "/mark/success/:habit_id" $ markHabit "succeeded" (difficulty_ . to scaleFactor) successes_
    Scotty.post "/mark/failure/:habit_id" $ markHabit "failed"(importance_ . to scaleFactor) failures_
    Scotty.post "/run" <<< wwwWriter $ runGame
--------------------------------- Quest Status ---------------------------------
    Scotty.get "/api/status" <<< apiReader $
      ask
      >>=
      (getAccountStatus >>> renderEventToXMLText >>> returnLazyText ok200)
    Scotty.get "/status" <<< wwwReader $
      (ask <&> getAccountStatus)
      >>=
      renderEventToHTMLAndReturn  "Habit of Fate - Quest Status" [] ok200
----------------------------------- Run Game -----------------------------------
    Scotty.post "/api/run" <<< apiWriter $ do
      runEvent >>= (renderEventToXMLText >>> returnLazyText ok200)
------------------------------------- Root -------------------------------------
    Scotty.get "/" $ Scotty.redirect "/habits"
--------------------------------- Style Sheets ---------------------------------
    addCSS "common" $ [cassius|
body
  background: #a2aeff
  font-family: Arial
|]
    addCSS "enter" $ [cassius|
.enter
  display: flex
  flex-direction: column
  margin-top: 100px
  margin-left: auto
  margin-right: auto
  width: 600px

.tabs
  bottom: 10px
  color: white
  display: flex
  flex-direction: row
  flex-wrap: nowrap
  margin-bottom: -10px
  margin-right: 20px
  position: relative

.active
  background: #728fff
  padding: 10px

.inactive
  background: #476bff
  padding: 10px

  a
    color: white

span.inactive:hover
    background: #5d7dff

form
  background: #728fff
  color: white
  font-family: Arial
  font-size: 20
  padding: 10px

  .fields
    display: flex
    flex-direction: column
    padding-bottom: 10px

    input
      background: #c3d0ff
      border: 0
      font-family: Arial
      font-size: 20
      padding: 5px

  #error-message
    color: #9b0000
    padding-bottom: 10px
|]
    addCSS "list" $ [cassius|
.list
  background-color: #728fff
  font-size: 24
  margin-top: 100px
  margin-left: auto
  margin-right: auto
  padding: 10px
  width: 600px

table
  border-collapse: collapse
  font-size: 24
  width: 600px

thead
  text-align: left

tbody
  tr:nth-child(even)
    background-color: #c3d0ff
  tr:nth-child(odd)
    background-color: #94aaff

.new-index
  width: 40px
|]
    addCSS "story" [cassius|
.bold-text
  font-weight: bold

.underlined-text
  text-decoration: underline

.red-text
  text-decoration-color: red

.blue-text
  text-decoration-color: blue

.green-text
  text-decoration-color: green

.introduce-text
  font-weight: bold
  text-decoration-color: cyan
|]
---------------------------------- Not Found -----------------------------------
    Scotty.notFound $ do
      r ← Scotty.request
      logIO [i|URL not found! #{requestMethod r} #{rawPathInfo r}#{rawQueryString r}|]
      Scotty.next

makeApp ∷
  Map Username Account →
  (Map Username Account → IO ()) →
  IO Application
makeApp = makeAppWithTestMode False

makeAppRunningInTestMode ∷
  Map Username Account →
  (Map Username Account → IO ()) →
  IO Application
makeAppRunningInTestMode = makeAppWithTestMode True

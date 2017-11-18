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
  ( FileLocator
  , Username(..)
  , makeApp
  ) where

import HabitOfFate.Prelude hiding (div, id, log)

import Data.Aeson hiding ((.=))
import Data.Aeson.Types
import Data.Containers
import Control.Concurrent
import Control.Concurrent.STM
import Control.DeepSeq
import Control.Exception (assert)
import Control.Monad.Operational (Program, ProgramViewT(..))
import Control.Monad.STM
import qualified Control.Monad.Operational as Operational
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as Lazy
import Data.Set (minView)
import qualified Data.Text.Lazy as Lazy
import Data.Time.Clock
import Data.UUID hiding (null)
import Data.Yaml hiding (Parser, (.=))
import GHC.Conc.Sync (unsafeIOToSTM)
import Network.HTTP.Types.Status
import Network.Wai
import System.IO (BufferMode(LineBuffering), hSetBuffering, stderr)
import System.Random
import Text.Blaze.Html (Html, ToMarkup, toHtml)
import Text.Blaze.Html.Renderer.Utf8 (renderHtml)
import Text.Hamlet (HtmlUrl, hamlet)
import Web.Cookie
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
import HabitOfFate.Game
import HabitOfFate.Habit
import HabitOfFate.Logging
import HabitOfFate.Story

--------------------------------------------------------------------------------
-------------------------------- Miscellaneous ---------------------------------
--------------------------------------------------------------------------------

instance Parsable UUID where
  parseParam = view strict >>> fromText >>> maybe (Left "badly formed UUID") Right

newtype Username = Username { unwrapUsername ∷ Text } deriving (Eq,Ord,Parsable,Read,Show)

instance FromJSON Username where
  parseJSON = parseJSON >>> fmap Username

instance FromJSON (Map Username Account) where
  parseJSON =
    (parseJSON ∷ Value → Parser (Map Text Account))
    >>>
    fmap (
      mapToList
      >>>
      map (first Username)
      >>>
      mapFromList
    )

instance ToJSON Username where
  toJSON = unwrapUsername >>> toJSON
  toEncoding = unwrapUsername >>> toEncoding

instance ToJSON (Map Username Account) where
  toJSON =
    mapToList
    >>>
    map (first unwrapUsername)
    >>>
    mapFromList
    >>>
    (toJSON ∷ Map Text Account → Value)

newtype Cookie = Cookie Text deriving (Eq,FromJSON,Ord,Parsable,Read,Show,ToJSON)

data Environment = Environment
  { accounts_tvar ∷ TVar (Map Username (TVar Account))
  , cookies_tvar ∷ TVar (Map Cookie (UTCTime, Username))
  , expirations_tvar ∷ TVar (Set (UTCTime, Cookie))
  , write_request_var ∷ TMVar ()
  }

readTVarMonadIO ∷ MonadIO m ⇒ TVar α → m α
readTVarMonadIO = readTVarIO >>> liftIO

--------------------------------------------------------------------------------
---------------------------- Shared Scotty Actions -----------------------------
--------------------------------------------------------------------------------

----------------------------------- Queries ------------------------------------

lookupHabit ∷ (ActionMonad m, MonadState Account m) ⇒ UUID → m Habit
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
setContent (HtmlContent h) = h |> toHtml |> renderHtml |> decodeUtf8 |> Scotty.html
setContent (JSONContent j) = Scotty.json j

setStatusAndLog ∷ Status → ActionM ()
setStatusAndLog status_@(Status code message) = do
  status status_
  let result
        | code < 200 || code >= 300 = "failed"
        | otherwise = "succeeded"
  logIO $ [i|Request #{result} - #{code} #{decodeUtf8 >>> unpack $ message}|]

data ProgramResult = ProgramResult Status Content

data Content =
    NoContent
  | TextContent Lazy.Text
  | HtmlContent Html
  | ∀ α. ToJSON α ⇒ JSONContent α

returnNothing ∷ Monad m ⇒ Status → m ProgramResult
returnNothing s = return $ ProgramResult s NoContent

returnLazyText ∷ Monad m ⇒ Status → Lazy.Text → m ProgramResult
returnLazyText s = TextContent >>> ProgramResult s >>> return

returnText ∷ Monad m ⇒ Status → Text → m ProgramResult
returnText s = view (from strict) >>> returnLazyText s

returnJSON ∷ (ToJSON α, Monad m) ⇒ Status → α → m ProgramResult
returnJSON s = JSONContent >>> ProgramResult s >>> return

returnHTML ∷ Monad m ⇒ Status → ((Page → Text) → Html) → m ProgramResult
returnHTML s = ($ renderPageURL) >>> HtmlContent >>> ProgramResult s >>> return

logRequest ∷ ActionM ()
logRequest = do
  r ← Scotty.request
  logIO $ [i|URL requested: #{requestMethod r} #{rawPathInfo r}#{rawQueryString r}|]

--------------------------------------------------------------------------------
--------------------------------- Action Monad ---------------------------------
--------------------------------------------------------------------------------

------------------------------------ Common ------------------------------------

data CommonInstruction α where
  GetBodyInstruction ∷ CommonInstruction Lazy.ByteString
  GetParamsInstruction ∷ CommonInstruction [Param]
  RaiseStatusInstruction ∷ Status → CommonInstruction α
  LogInstruction ∷ String → CommonInstruction ()

class Monad m ⇒ ActionMonad m where
  singletonCommon ∷ CommonInstruction α → m α

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
            [i|[#{username}]: #{message}|] |> singleton |> tell
            interpret (rest ())
        ReaderViewInstruction → interpret (rest account)
      (error_or_result, logs) = program |> interpret |> runExceptT |> runWriter
  traverse_ logIO logs
  case error_or_result of
    Left status_ →
      setStatusAndLog status_
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
        Program WriterInstruction α →
        StateT Account (ExceptT Status (Writer (Seq String))) α
      interpret (Operational.view → Return result) = pure result
      interpret (Operational.view → instruction :>>= rest) = case instruction of
        WriterCommonInstruction common_instruction → case common_instruction of
          GetBodyInstruction → interpret (rest body_)
          GetParamsInstruction → interpret (rest params_)
          RaiseStatusInstruction s → throwError s
          LogInstruction message → do
            [i|[#{username}]: #{message}|] |> singleton |> tell
            interpret (rest ())
        WriterGetAccountInstruction → get >>= (rest >>> interpret)
        WriterPutAccountInstruction new_account → put new_account >> interpret (rest ())
  (status_, maybe_content, logs) ← atomically >>> liftIO $ do
    old_account ← readTVar account_tvar
    let (error_or_result, logs) =
          interpret program
            |> flip runStateT old_account
            |> runExceptT
            |> runWriter
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
------------------------------ Server Application ------------------------------
--------------------------------------------------------------------------------

type FileLocator = FilePath → IO (Maybe FilePath)

data Page = Habits
renderPageURL ∷ Page → Text
renderPageURL Habits = "/habits"

makeApp ∷
  Bool →
  FileLocator →
  Map Username Account →
  (Map Username Account → IO ()) →
  IO Application
makeApp test_mode locateWebAppFile initial_accounts saveAccounts = do
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
          cookie ← (pack >>> Cookie) <$> (replicateM 10 $ randomRIO ('a','z'))
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

      getContent filename =
        logIO [i|Getting content #{filename}|]
        >>
        (liftIO $ locateWebAppFile filename)
        >>=
        \case
          Nothing → do
            logIO "File not found."
            setStatusAndLog notFound404
          Just filepath → do
            logIO [i|File found at "#{filepath}".|]
            Scotty.file filepath

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
    let createAccountAction = do
          logRequest
          username@(Username username_) ← Username <$> paramOrBlank "username"
          password1 ← paramOrBlank "password1"
          password2 ← paramOrBlank "password2"
          when ((not . onull $ password1) && password1 == password2) $ do
            logIO $ [i|Request to create an account for "#{username_}".|]
            liftIO >>> join $ do
              new_account ← newAccount password1
              atomically $ do
                accounts ← readTVar accounts_tvar
                if member username accounts
                  then pure $ do
                    logIO $ [i|Account "#{username_}" already exists!|]
                    status conflict409
                  else do
                    account_tvar ← newTVar new_account
                    modifyTVar accounts_tvar $ insertMap username account_tvar
                    pure $ do
                      logIO $ [i|Account "#{username_}" successfully created!|]
                      createAndReturnCookie username
                      Scotty.redirect "/"
          let error_message ∷ Text =
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
          (($ renderPageURL) >>> renderHtml >>> decodeUtf8 >>> Scotty.html) [hamlet|
<head>
  <title>Account creation
<body>
  <form method="post">
    <div>
      <table>
        <tr>
          <td> Username
          <td>
            <input type="text" name="username" value="#{username_}">
        <tr>
          <td> Password
          <td>
            <input type="password" name="password1">
        <tr>
          <td> Password (again)
          <td>
            <input type="password" name="password2">
    $if (not . onull) error_message
      <div>#{error_message}
    <div>
      <input type="submit" formmethod="post"/>
      <a href="/login">Login
|]
    Scotty.get "/create" createAccountAction
    Scotty.post "/create" createAccountAction
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
                    logIO [i|Incorrect password for #{username_}.|]
                    pure "No account has that username."
                  Just account_tvar → do
                    account ← readTVarMonadIO account_tvar
                    if passwordIsValid password account
                      then do
                        logIO [i|Successfully logged in #{username_}.|]
                        createAndReturnCookie username
                        Scotty.redirect "/"
                      else do
                        logIO [i|Incorrect password for #{username_}.|]
                        pure "No account has that username."
          (($ renderPageURL) >>> renderHtml >>> decodeUtf8 >>> Scotty.html) [hamlet|
<head>
  <title>Account creation
<body>
  <form method="post">
    <div>
      <table>
        <tr>
          <td> Username
          <td>
            <input type="text" name="username" value="#{username_}">
        <tr>
          <td> Password
          <td>
            <input type="password" name="password">
    $if (not . onull) error_message
      <div>#{error_message}
    <div>
      <input type="submit" formmethod="post"/>
      <a href="/create">Create
|]
    Scotty.get "/login" loginAction
    Scotty.post "/login" loginAction
-------------------------------- Get All Habits --------------------------------
    Scotty.get "/api/habits" <<< apiReader $ do
      log "Requested all habits."
      view habits >>= returnJSON ok200
    Scotty.get "/habits" <<< wwwReader $ do
      habits_ ← view habits
      returnHTML ok200 [hamlet|
<head>
  <title>List of habits
<body>
  <ol>
    $forall habit <- habits_
      <li> #{habit ^. name}
|]
---------------------------------- Get Habit -----------------------------------
    let habitAction foundAction = do
          habit_id ← getParam "habit_id"
          log $ [i|Requested habit with id #{habit_id}.|]
          habits_ ← view habits
          case lookup habit_id habits_ of
            Nothing → raiseNoSuchHabit
            Just habit → foundAction habit

            Just habit → returnJSON ok200 habit
    Scotty.get "/api/habits/:habit_id" <<< apiReader $
      habitAction (returnJSON ok200)
--------------------------------- Delete Habit ---------------------------------
    Scotty.delete "/api/habits/:habit_id" <<< apiWriter $ do
      habit_id ← getParam "habit_id"
      log $ [i|Requested to delete habit with id #{habit_id}.|]
      habit_was_there ← isJust <$> (habits . at habit_id <<.= Nothing)
      returnNothing $
        if habit_was_there
          then noContent204
          else notFound404
---------------------------------- Put Habit -----------------------------------
    Scotty.put "/api/habits/:habit_id" <<< apiWriter $ do
      habit_id ← getParam "habit_id"
      log $ [i|Requested to put habit with id #{habit_id}.|]
      habit ← getBodyJSON
      habit_was_there ← isJust <$> (habits . at habit_id <<.= Just habit)
      returnNothing $
        if habit_was_there
          then noContent204
          else created201
--------------------------------- Get Credits ----------------------------------
    Scotty.get "/api/credits" <<< apiReader $ do
      log $ "Requested credits."
      view (game . credits) >>= returnJSON ok200
--------------------------------- Mark Habits ----------------------------------
    Scotty.post "/api/mark" <<< apiWriter $ do
      marks ← getBodyJSON
      let markHabits ∷
            (HabitsToMark → [UUID]) →
            (Habit → Scale) →
            Lens' Account Double →
            WriterProgram Double
          markHabits getUUIDs getScale value_lens = do
            old_value ← use value_lens
            increment ∷ Double ←
              marks
                |> getUUIDs
                |> mapM (lookupHabit >>> fmap (getScale >>> scaleFactor))
                |> fmap sum
            value_lens <.= old_value + increment
      log $ [i|Marking #{marks ^. successes} successes and #{marks ^. failures} failures.|]
      (Credits
          <$> (markHabits (^. successes) (^. difficulty) (game . credits . success))
          <*> (markHabits (^. failures ) (^. importance) (game . credits . failure))
       ) >>= returnJSON ok200
----------------------------------- Run Game -----------------------------------
    Scotty.post "/api/run" <<< apiWriter $ do
      let go d = do
            let r = runAccount d
            l_ #quest_events %= (⊢ r ^. story . to createEvent)
            if stillHasCredits (r ^. new_data)
              then do
                when (r ^. quest_completed) $
                  (l_ #quest_events <<.= mempty)
                  >>=
                  (createQuest >>> (⊣) >>> (l_ #quests %=))
                go (r ^. new_data)
              else return (r ^. new_data)
      (new_d, s) ←
        get
        >>=
        (
          go
          >>>
          flip runStateT
            ( #quests := (mempty ∷ Seq Quest)
            , #quest_events := (mempty ∷ Seq Event)
            )
        )
      put new_d
      returnLazyText ok200 $!! (
        s ^. l_ #quests ⊢ s ^. l_ #quest_events . to createQuest
        |> createStory
        |> renderStoryToText
       )
------------------------------------- Root -------------------------------------
    Scotty.get "/" $ Scotty.redirect "/habits"
---------------------------------- Not Found -----------------------------------
    Scotty.notFound $ do
      r ← Scotty.request
      logIO $ [i|URL not found! #{requestMethod r} #{rawPathInfo r}#{rawQueryString r}|]
      Scotty.next

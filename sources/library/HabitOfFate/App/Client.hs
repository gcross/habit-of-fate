{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UnicodeSyntax #-}

module HabitOfFate.App.Client where

import HabitOfFate.Prelude hiding (argument)

import Control.Exception (AsyncException(UserInterrupt))
import Control.Monad.Base
import Control.Monad.Catch
import Control.Monad.Cont
import Control.Monad.Trans.Control
import qualified Data.ByteString as BS
import Data.Char
import qualified Data.Text.IO as S
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Options.Applicative
import Rainbow.Translate
import System.IO
import System.IO.Error (isEOFError)
import System.Random
import Text.Read (readEither, readMaybe)
import Text.XML

import HabitOfFate.Client
import HabitOfFate.Credits
import HabitOfFate.Habit
import HabitOfFate.Story

data Quit = Quit

type InnerAction = ExceptT Quit ClientIO

newtype ActionMonad α = ActionMonad
  { unwrapActionMonad ∷ InnerAction α }
  deriving
  ( Applicative
  , Functor
  , Monad
  , MonadBase IO
  , MonadCatch
  , MonadError Quit
  , MonadIO
  , MonadThrow
  )

instance MonadBaseControl IO ActionMonad where
  type StM ActionMonad α = StM InnerAction α
  liftBaseWith f = ActionMonad $ liftBaseWith $ \r → f (unwrapActionMonad >>> r)
  restoreM = restoreM >>> ActionMonad

quit ∷ ActionMonad α
quit = throwError Quit

class Monad m ⇒ MonadClient m where
  liftC ∷ ClientIO α → m α

instance MonadClient ActionMonad where
  liftC = lift >>> ActionMonad

data Action = Action
  { _key ∷ Char
  , _description ∷ String
  , _code ∷ ActionMonad ()
  }
makeLenses ''Action

printHelp ∷ MonadIO m ⇒ [Action] → m ()
printHelp actions = liftIO $ do
  putStrLn "Actions:"
  forM_ actions $ \action →
    putStrLn [i|  #{action ^. key}: #{action ^. description}|]
  putStrLn "  --"
  putStrLn "  q: Quit this menu."
  putStrLn "  ?: Display this help message."

data Cancel = Cancel

type ActionMonadWithCancel = ExceptT Cancel ActionMonad

instance MonadClient ActionMonadWithCancel where
  liftC = liftC >>> lift

cancel ∷ ActionMonadWithCancel α
cancel = liftIO (putStrLn "") >> throwError Cancel

class EditableValue α where
  showValue ∷ α → String
  default showValue ∷ Show α ⇒ α → String
  showValue = show

  parseValue ∷ String → Maybe α
  default parseValue ∷ Read α ⇒ String → Maybe α
  parseValue = readMaybe

instance EditableValue String where
  showValue = identity
  parseValue = Just

instance EditableValue Double where

instance EditableValue UUID where

instance EditableValue [UUID] where
  showValue = map showValue >>> intercalate ","
  parseValue = split1 >>> map parseValue >>> sequence
    where
      isSep = flip elem (" ," :: String)

      split1 = dropWhile isSep >>> split2

      split2 [] = []
      split2 x = entry:split1 rest
        where
          (entry,rest) = break isSep x

instance EditableValue Scale where
  showValue = show >>> unpack
  parseValue = pack >>> readMaybe

prompt ∷ EditableValue α ⇒ String → ActionMonadWithCancel α
prompt p =
  promptForString
  >>=
  (
    parseValue
    >>>
    maybe (liftIO (putStrLn "Bad input.") >> prompt p) return
  )
  where
    promptForString =
      liftIO >>> join $ do
        putStr p
        putChar ' '
        hFlush stdout
        handleJust
          (\e →
            (
              case fromException e of
                Just UserInterrupt → Just cancel
                _ → Nothing
            )
            <|>
            (
              isEOFError <$> fromException e
              >>=
              bool Nothing (Just $ liftIO (putStrLn "") >> lift quit)
            )
          )
          return
          (return <$> getLine)

promptWithDefault ∷ (EditableValue α, Show α) ⇒ α → String → ActionMonadWithCancel α
promptWithDefault def p = doPrompt
  where
    doPrompt =
      prompt [i|#{p} [#{def}]|]
      >>=
      (\input →
        if null input
          then return def
          else case parseValue input of
            Nothing → doPrompt
            Just value → return value
      )

promptForCommand ∷ MonadIO m ⇒ String → m Char
promptForCommand p =
  (
    bracket_
      (hSetBuffering stdin NoBuffering)
      (hSetBuffering stdin LineBuffering)
    >>>
    liftIO
  )
  $
  do putStr p
     putChar ' '
     hFlush stdout
     command ← getChar
     putStrLn ""
     return command

unrecognizedCommand ∷ MonadIO m ⇒ Char → m ()
unrecognizedCommand command
  | not (isAlpha command) = return ()
  | otherwise = liftIO $
      putStrLn [i|Unrecognized command '#{command}'.  Press ? for help.\n|]

data Escape = Escape

loop ∷ [String] → [Action] → ActionMonad ()
loop labels actions = runExceptT >>> void $ do
  let action_map =
        [(chr 4, lift quit)
        ,(chr 27, throwError Escape)
        ,('q', throwError Escape)
        ,('?',printHelp actions)
        ]
        ⊕
        (map ((^. key) &&& (^. code . to lift)) actions)
  forever $ do
    command ← promptForCommand $
      let location = ointercalate "|" $ "HoF":labels
          action_keys = map (^. key) actions
      in [i|#{location}[#{action_keys}q?]>|]
    case lookup command action_map of
      Nothing → unrecognizedCommand command
      Just code → code `catchAll` (show >>> putStrLn >>> liftIO)

withCancel ∷ ActionMonadWithCancel () → ActionMonad ()
withCancel = runExceptT >>> void

printAndCancel = putStrLn >>> liftIO >>> (>> cancel)

mainLoop ∷ ActionMonad ()
mainLoop = loop [] $
  [Action 'h' "Edit habits." <<< loop ["Habits"] $
    [Action 'a' "Add a habit." <<< withCancel $ do
      habit_id ← liftIO randomIO
      habit ← Habit
        <$> prompt "What is the name of the habit?"
        <*> promptWithDefault Medium "Importance [very low, low, medium, high, very high]?"
        <*> promptWithDefault Medium "Difficulty [very low, low, medium, high, very high]?"
      liftC >>> void $ putHabit habit_id habit
    ,Action 'e' "Edit a habit." <<< withCancel $ do
      habit_id ← prompt "Which habit?"
      old_habit ←
        liftC (getHabit habit_id)
        >>=
        maybe
          (printAndCancel "No such habit.")
          return
      habit ← Habit
        <$> promptWithDefault (old_habit ^. name) "What is the name of the habit?"
        <*> promptWithDefault Medium "Importance [very low, low, medium, high, very high]?"
        <*> promptWithDefault Medium "Difficulty [very low, low, medium, high, very high]?"
      liftC >>> void $ putHabit habit_id habit
    ,Action 'f' "Mark habits as failed." $
       withCancel $ prompt "Which habits failed?" >>= (markHabits [] >>> liftC >>> void)
    ,Action 'p' "Print habits." $ printHabits
    ,Action 's' "Mark habits as successful." $
       withCancel $ prompt "Which habits succeeded?" >>= (flip markHabits [] >>> liftC >>> void)
    ]
  ,Action 'p' "Print data." $ do
      liftIO $ putStrLn "Habits:"
      printHabits
      liftIO $ putStrLn ""
      liftIO $ putStrLn "Game:"
      credits ← liftC getCredits
      liftIO $ putStrLn [i|    Success credits: #{credits ^. success}|]
      liftIO $ putStrLn [i|    Failure credits: #{credits ^. failure}|]
  ,Action 'r' "Run game." $ do
      story ← liftC runGame
      printer ← liftIO byteStringMakerFromEnvironment
      story
        |> renderStoryToChunks
        |> chunksToByteStrings printer
        |> traverse_ BS.putStr
        |> liftIO
  ]
  where
    printHabits = do
      habits ← liftC getHabits
      liftIO $
        if null habits
          then putStrLn "There are no habits."
          else forM_ (mapToList habits) $ \(uuid, habit) →
            printf "%s %s [+%s/-%s]\n"
              (show uuid)
              (habit ^. name)
              (show $ habit ^. difficulty)
              (show $ habit ^. importance)

data Configuration = Configuration
  { hostname ∷ String
  , port ∷ Int
  , create_account_mode ∷ Bool
  }

configuration_parser ∷ Parser Configuration
configuration_parser = Configuration
  <$> strArgument (mconcat
        [ metavar "HOSTNAME"
        , help "Name of the host to connect to."
        , value "localhost"
        ])
  <*> argument auto (mconcat
        [ metavar "PORT"
        , help "Port to connect to."
        , value 8081
        ])
  <*> switch (mconcat
        [ help "Create a new account."
        , long "create"
        , short 'c'
        ])

runSession ∷ SessionInfo → IO ()
runSession session_info =
  mainLoop
    |> unwrapActionMonad
    |> runExceptT
    |> flip runClientT session_info
    |> void

doMain ∷ IO ()
doMain = do
  Configuration{..} ←
    execParser $ info
      (configuration_parser <**> helper)
      (   fullDesc
       <> header "habit-client - a client program for habit-of-fate"
      )
  putStr "Username: "
  hFlush stdout
  username ← getLine
  putStr "Password: "
  hFlush stdout
  hSetEcho stdout False
  password ← getLine
  hSetEcho stdout True
  putStrLn ""
  let doLogin =
        login username password Secure "localhost" 8081
        >>=
        either
          (\case
            NoSuchAccount → putStrLn "No such account."
            InvalidPassword → putStrLn "Invalid password."
          )
          runSession
  if create_account_mode
    then
      createAccount username password Secure "localhost" 8081
      >>=
      maybe
        (putStrLn "Account already exists. Logging in..." >> doLogin)
        runSession
    else doLogin
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE UnicodeSyntax #-}

module Main where

import Control.Exception
import Control.Lens
import Control.Monad.Cont
import Control.Monad.Error.Lens
import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State
import Data.Bool
import Data.Char
import Data.IORef
import Data.Foldable
import Data.List
import Data.Maybe
import qualified Data.Sequence as Seq
import Data.UUID ()
import System.Console.ANSI
import System.Directory
import System.IO
import System.Random
import Text.Printf
import Text.Read (readEither, readMaybe)

import HabitOfFate.Behaviors.Habit
import qualified HabitOfFate.Behaviors.Habit as Habit
import HabitOfFate.Console
import HabitOfFate.Data
import HabitOfFate.Game (GameState, belief)
import qualified HabitOfFate.Game as Game
import HabitOfFate.Unicode

data Quit = BadInput | CtrlC | CtrlD
makePrisms ''Quit

newtype ActionMonad α = ActionMonad
  { unwrapActionMonad ∷ ReaderT (IORef Data) (ExceptT Quit (ContT () IO)) α
  } deriving (Applicative, Functor, Monad, MonadCont, MonadError Quit, MonadIO)

instance MonadState Data ActionMonad where
  get = ActionMonad $ ask >>= liftIO . readIORef
  put x = ActionMonad $ ask >>= liftIO . flip writeIORef x

data Action = Action
  { _description ∷ String
  , _code ∷ ActionMonad ()
  }
makeLenses ''Action

type ActionMap = [(Char,Action)]

help ∷ MonadIO m ⇒ ActionMap → m ()
help commands = liftIO $ do
  putStrLn "Commands:"
  forM_ commands $ \(command, action) →
    printf "  %c: %s\n" command (action ^. description)
  putStrLn "  --"
  putStrLn "  q: Quit this menu."
  putStrLn "  ?: Display this help message."

ctrlC ∷ ActionMonad α
ctrlC = throwError CtrlC

prompt ∷  String → ActionMonad String
prompt p =
  (liftIO $ do
    putStr p
    putChar ' '
    hFlush stdout
    handleJust
      (\case
        UserInterrupt → Just ()
        _ → Nothing
      )
      (const $ return Nothing)
      (Just <$> getLine)
  )
  >>=
  maybe ctrlC return

parseNumberOrRepeat ∷ Int → String → ActionMonad Int
parseNumberOrRepeat top input =
  case (readMaybe input ∷ Maybe Int) of
    Nothing → liftIO (printf "Invalid number: %s\n" input) >> throwError BadInput
    Just n
      | 1 ≤ n && n ≤ top → return (n-1)
      | otherwise → liftIO (putStrLn "Out of range.") >> throwError BadInput

promptForIndex ∷  Int → String → ActionMonad Int
promptForIndex top p =
  handling_ _BadInput (promptForIndex top p)
  $
  prompt (printf "%s [1-%i]" p top)
  >>=
  parseNumberOrRepeat top

promptForIndices ∷  Int → String → ActionMonad [Int]
promptForIndices top p =
  handling_ _BadInput (promptForIndices top p)
  $
  prompt (printf "%s [1-%i]" p top)
  >>=
  mapM (parseNumberOrRepeat top) ∘ splitEntries
  where
    isSeparator ' ' = True
    isSeparator ',' = True
    isSeparator _ = False

    splitEntries [] = []
    splitEntries entries = entry:splitEntries (dropWhile isSeparator rest)
      where
        (entry,rest) = break isSeparator entries

promptForCommand ∷ MonadIO m ⇒ String → m Char
promptForCommand p =
  liftIO
  .
  bracket_
    (hSetBuffering stdin NoBuffering)
    (hSetBuffering stdin LineBuffering)
  $ do
  putStr p
  putChar ' '
  hFlush stdout
  command ← getChar
  putStrLn ""
  return command

promptWithDefault ∷  String → String → ActionMonad String
promptWithDefault def p =
  prompt (printf "%s [%s]" p def)
  <&>
  (\input → if null input then def else input)

promptWithDefault' ∷ (Read α, Show α) ⇒  α → String → ActionMonad α
promptWithDefault' def p = doPrompt
  where
    doPrompt =
      promptWithDefault (show def) p
      >>=
      handleParseResult . readEither
    handleParseResult (Left e) = liftIO (putStrLn e) >> doPrompt
    handleParseResult (Right x) = return x

unrecognizedCommand ∷ MonadIO m ⇒ Char → m ()
unrecognizedCommand command
  | not (isAlpha command) = return ()
  | otherwise = liftIO $
      printf "Unrecognized command '%c'.  Press ? for help.\n" command

loop ∷ [String] → ActionMap → ActionMonad ()
loop labels commands = go
  where
    go =
      (promptForCommand $ printf "%s[%sq?]>"
        (intercalate "|" ("HoF":labels))
        (map fst commands)
      )
      >>=
      \command →
        fromMaybe (unrecognizedCommand command >> go)
        ∘
        lookup command
        $
        (chr 4, throwError CtrlD)
        :
        (chr 27, return ())
        :
        ('q',return ())
        :
        ('?',help commands >> go)
        :
        map (_2 %~ (>> go) ∘ view code) commands

printHabit = printf "%s [+%f/-%f]\n"
  <$> (^. name)
  <*> (^. success_credits)
  <*> (^. failure_credits)

getNumberOfHabits ∷ ActionMonad Int
getNumberOfHabits = length <$> use habits

gameStillHasCredits ∷ ActionMonad Bool
gameStillHasCredits =
  (||)
    <$> ((/= 0) <$> use (game . Game.success_credits))
    <*> ((/= 0) <$> use (game . Game.failure_credits))

catchCtrlC ∷ ActionMonad () → ActionMonad ()
catchCtrlC = handling_ _CtrlC (liftIO $ putStrLn "")

mainLoop ∷ ActionMonad ()
mainLoop = loop [] $
  [('h',) ∘ Action "Edit habits." ∘ loop ["Habits"] $
    [('a',) ∘ Action "Add a habit." ∘ catchCtrlC $
      Habit
        <$> liftIO randomIO
        <*> prompt "What is the name of the habit?"
        <*> promptWithDefault' 1.0 "How many credits is a success worth?"
        <*> promptWithDefault' 0.0 "How many credits is a failure worth?"
      >>=
      (habits %=) ∘ flip (|>)
    ,('e',) ∘ Action "Edit a habit." ∘ catchCtrlC $ do
      number_of_habits ← getNumberOfHabits
      abortIfNoHabits number_of_habits
      index ← promptForIndex number_of_habits "Which habit?"
      old_habit ←  fromJust <$> preuse (habits . ix index)
      new_habit ←
        Habit
          <$> (return $ old_habit ^. uuid)
          <*> promptWithDefault (old_habit ^. name) "What is the name of the habit?"
          <*> promptWithDefault' (old_habit ^. success_credits) "How many credits is a success worth?"
          <*> promptWithDefault' (old_habit ^. failure_credits) "How many credits is a failure worth?"
      habits . ix index .= new_habit
    ,('f',) ∘ Action "Mark habits as failed." $
       markHabits "Failure" Habit.failure_credits Game.failure_credits
    ,('p',) ∘ Action "Print habits." $ printHabits
    ,('s',) ∘ Action "Mark habits as successful." $
       markHabits "Success" Habit.success_credits Game.success_credits
    ]
  ,('p',) ∘ Action "Print data." $ do
      liftIO $ putStrLn "Habits:"
      printHabits
      liftIO $ putStrLn ""
      liftIO $ putStrLn "Game:"
      let printCredits name =
            use . (game .)
            >=>
            liftIO ∘ printf "    %s credits: %f\n" name
      printCredits "Success" Game.success_credits
      printCredits "Failure" Game.failure_credits
      use (game . belief) >>= liftIO . printf "    Belief: %i\n"
      liftIO $ putStrLn ""
      use quest >>= liftIO . putStrLn . show
  ,('r',) ∘ Action "Run game." $
      gameStillHasCredits
      >>=
      bool
        (liftIO $ putStrLn "No credits.")
        (do
          liftIO $ putStrLn ""
          callCC $ \quit → forever $ do
            r ← get <&> runData
            put $ r ^. new_data
            liftIO ∘ printParagraphs $ r ^. paragraphs
            gameStillHasCredits
              >>=
              bool
                (quit ())
                (do
                  liftIO $ do
                    putStrLn ""
                    pressAnyKeyToContinue
                    if r ^. quest_completed
                      then do
                        putStrLn $ replicate 80 '='
                        putStrLn "A new quest begins..."
                        putStrLn $ replicate 80 '='
                      else do
                        putStrLn $ replicate 80 '-'
                    putStrLn ""
                    pressAnyKeyToContinue
                )
          liftIO $ putStrLn ""
        )
  ]
  where
    abortIfNoHabits number_of_habits =
      when (number_of_habits == 0) $ do
        liftIO $ putStrLn "There are no habits."
        ctrlC

    getGameCreditsAsFloat =
      ((/ (100 ∷ Float)) ∘ fromIntegral <$>)
      ∘
      use
      ∘
      (game .)

    pressAnyKeyToContinue = do
      putStrLn "[Press any key to continue.]"
      bracket_
        (do hSetBuffering stdin NoBuffering
            hSetEcho stdin False
        )
        (do hSetBuffering stdin LineBuffering
            hSetEcho stdin True
        )
        (void getChar)
      cursorUpLine 1
      clearLine

    printHabits = do
      habits' ← use habits
      if Seq.null habits'
        then liftIO $ putStrLn "There are no habits."
        else forM_ (zip [1..] (toList habits')) $
          liftIO
          ∘
          (\(n,habit) → do
            printf "%i. " (n ∷ Int)
            printHabit habit
          )

    markHabits ∷ String → Lens' Habit Double → Lens' GameState Double → ActionMonad ()
    markHabits name habit_credits game_credits = catchCtrlC $ do
      number_of_habits ← getNumberOfHabits
      abortIfNoHabits number_of_habits
      indices ← promptForIndices number_of_habits "Which habits?"
      old_success_credits ← use $ game . game_credits
      forM_ indices $ \index →
        preuse (habits . ix index . habit_credits)
        >>=
        (game . game_credits +=) ∘ fromJust
      new_success_credits ← use $ game . game_credits
      liftIO $
        printf "%s credits went from %f to %f\n"
          name
          old_success_credits
          new_success_credits

main ∷ IO ()
main = do
  filepath ← getDataFilePath
  old_data ←
    doesFileExist filepath
    >>=
    bool newData
         (readData filepath)
  let run current_data = do
        new_data_ref ← newIORef current_data
        void
          ∘
          flip runContT return
          ∘
          void
          ∘
          runExceptT
          ∘
          flip runReaderT new_data_ref
          ∘
          unwrapActionMonad
          $
          mainLoop
        new_data ← readIORef new_data_ref
        when (new_data /= old_data) $
          let go =
                promptForCommand "Save changes? [yna]"
                >>=
                \case
                  'y' → writeData filepath new_data
                  'n' → return ()
                  'a' → run new_data
                  _ → putStrLn "Please type either 'y', 'n', or 'a''." >> go
          in go
  run old_data

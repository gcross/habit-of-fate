{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UnicodeSyntax #-}

module HabitOfFate.Account where

import HabitOfFate.Prelude

import Control.Exception
import Control.Monad.Random
import Crypto.PasswordStore
import Data.Aeson
import Data.Map (Map)
import Data.UUID (UUID)
import System.Directory
import System.FilePath

import HabitOfFate.Credits
import HabitOfFate.Game
import HabitOfFate.Habit
import HabitOfFate.JSON ()
import HabitOfFate.Quests
import HabitOfFate.Story
import HabitOfFate.TH

instance ToJSON StdGen where
  toJSON = toJSON ∘ show

instance FromJSON StdGen where
  parseJSON = fmap read ∘ parseJSON

data Account = Account
  {   _password ∷ Text
  ,   _habits ∷ Map UUID Habit
  ,   _game ∷ GameState
  ,   _quest ∷ Maybe CurrentQuestState
  ,   _rng :: StdGen
  } deriving (Read,Show)
deriveJSON ''Account
makeLenses ''Account

newAccount ∷ Text → IO Account
newAccount password =
  Account
    <$> (
          makePassword (encodeUtf8 password) 17
          >>=
          evaluate ∘ decodeUtf8
        )
    <*> pure mempty
    <*> pure newGame
    <*> pure Nothing
    <*> newStdGen

passwordIsValid ∷ Text → Account → Bool
passwordIsValid password_ account =
  verifyPassword (encodeUtf8 password_) (encodeUtf8 $ account ^. password)

data RunAccountResult = RunAccountResult
  { _story ∷ Seq Paragraph
  , _quest_completed ∷ Bool
  , _new_data ∷ Account
  }
makeLenses ''RunAccountResult

runAccount ∷ Account → RunAccountResult
runAccount d =
  (flip runRand (d ^. rng)
   $
   runGame (d ^. game) (runCurrentQuest (d ^. quest))
  )
  &
  \(r, new_rng) →
    RunAccountResult
      (r ^. game_paragraphs)
      (isNothing (r ^. returned_value))
      (d & game .~ r ^. new_game
         & quest .~ r ^. returned_value
         & rng .~ new_rng
      )

stillHasCredits ∷ Account → Bool
stillHasCredits d = (||)
  (d ^. game . credits . success /= 0)
  (d ^. game . credits . failure /= 0)

data HabitsToMark = HabitsToMark
  { _successes ∷ [UUID]
  , _failures ∷ [UUID]
  } deriving (Eq, Ord, Read, Show)
deriveJSON ''HabitsToMark
makeLenses ''HabitsToMark

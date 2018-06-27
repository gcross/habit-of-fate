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

{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UnicodeSyntax #-}

module HabitOfFate.Quests where

import HabitOfFate.Prelude

import HabitOfFate.Game
import qualified HabitOfFate.Quests.Forest as Forest
import HabitOfFate.Quest
import HabitOfFate.TH

data CurrentQuestState =
    Forest Forest.State
  deriving (Eq,Ord,Read,Show)
deriveJSON ''CurrentQuestState
makePrisms ''CurrentQuestState


data Quest = ∀ α. Quest
  (Prism' CurrentQuestState α)
  (Game α)
  (QuestAction α QuestStatus)

quests ∷ [Quest]
quests =
  [Quest _Forest Forest.new Forest.run
  ]

runCurrentQuest ∷ Maybe CurrentQuestState → Game (Maybe CurrentQuestState)
runCurrentQuest Nothing =
  uniform quests
  >>=
  (\(Quest prism new _) → (Just . (^.re prism)) <$> new)
runCurrentQuest (Just state) = go quests
  where
    go ∷ [Quest] → Game (Maybe CurrentQuestState)
    go [] = error "Unrecognized quest type"
    go (Quest prism _ action:rest) =
      case state ^? prism of
        Nothing → go rest
        Just x → fmap (^.re prism) <$> runQuest x action

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

import HabitOfFate.Data.Tagged
import qualified HabitOfFate.Quests.Forest as Forest
import HabitOfFate.Quest
import HabitOfFate.TH

data CurrentQuestState =
    Forest Forest.State
  deriving (Eq,Ord,Read,Show)
deriveJSON ''CurrentQuestState
makePrisms ''CurrentQuestState

data Quest s = Quest
  { questPrism ∷ Prism' CurrentQuestState s
  , questInitialize ∷ InitializeQuestRunner s
  , questGetStatus ∷ GetStatusQuestRunner s
  , questTrial ∷ Tagged (TrialQuestRunner s)
  }

data WrappedQuest = ∀ s. WrappedQuest (Quest s)

quests ∷ [WrappedQuest]
quests =
  [WrappedQuest $
     Quest
       _Forest
       Forest.initialize
       Forest.getStatus
       (Tagged (Success Forest.trialSuccess) (Failure Forest.trialFailure))
  ]

type RunCurrentQuestResult = RunQuestResult CurrentQuestState

runCurrentQuest ∷ (∀ s. Quest s → s → α) → CurrentQuestState → α
runCurrentQuest f current_quest_state =
  foldr
    (\(WrappedQuest quest) rest →
      case current_quest_state ^? (questPrism quest) of
        Nothing → rest
        Just quest_state → f quest quest_state
    )
    (error "Unrecognized quest type")
    quests

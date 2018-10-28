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

{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UnicodeSyntax #-}

module HabitOfFate.Quest where

import HabitOfFate.Prelude

import Control.Monad.Random

import HabitOfFate.Data.Tagged
import HabitOfFate.Story

data InitializeQuestResult α = InitializeQuestResult
  { initialQuestState ∷ α
  , initialQuestEvent ∷ Event
  }
makeLenses ''InitializeQuestResult

data RunQuestResult s = RunQuestResult
  { maybeRunQuestState ∷ Maybe s
  , runQuestEvent ∷ Event
  } deriving (Functor)
makeLenses ''RunQuestResult

data QuestStatus = QuestInProgress | QuestHasEnded

data TryQuestResult = TryQuestResult
  { tryQuestStatus ∷ QuestStatus
  , tryQuestPostAvailableCredits ∷ Tagged Double
  , tryQuestEvent ∷ Event
  }

type InitializeQuestRunner s = Rand StdGen (InitializeQuestResult s)
type GetStatusQuestRunner s = s → Event
type TrialQuestRunner s = Tagged Double → StateT s (Rand StdGen) TryQuestResult

uniformAction ∷ MonadRandom m ⇒ [m α] → m α
uniformAction = uniform >>> join

weightedAction ∷ MonadRandom m ⇒ [(m α, Rational)] → m α
weightedAction = weighted >>> join

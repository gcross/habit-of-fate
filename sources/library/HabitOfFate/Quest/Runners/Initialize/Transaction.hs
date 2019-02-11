{-
    Habit of Fate, a game to incentivize habit formation.
    Copyright (C) 2019 Gregory Crosswhite

    This program is free software: you can redistribute it and/or modify
    it under version 3 of the terms of the GNU Affero General Public License.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
-}

{-# LANGUAGE AutoDeriveTypeable #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE UnicodeSyntax #-}

module HabitOfFate.Quest.Runners.Initialize.Transaction where

import HabitOfFate.Prelude

import Control.Monad.Catch (MonadThrow(throwM))
import Control.Monad.Operational (interpretWithMonad)
import Control.Monad.Random (uniform)
import System.Random.Shuffle (shuffleM)

import HabitOfFate.Quest.Classes
import HabitOfFate.Quest.Runners.Initialize
import HabitOfFate.Server.Transaction

runInTransaction ∷ Program α → Transaction α
runInTransaction = unwrapProgram >>> interpretWithMonad interpret
 where
  interpret ∷ ∀ β. Instruction β → Transaction β
  interpret (Instruction_AllocateName gender) = allocateName gender
  interpret (Instruction_ChooseFrom list) = uniform list
  interpret (Instruction_ShuffleFrom list) = shuffleM list
  interpret (Instruction_Throw exc) = throwM exc

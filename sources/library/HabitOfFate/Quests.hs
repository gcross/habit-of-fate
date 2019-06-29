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

{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE UnicodeSyntax #-}

module HabitOfFate.Quests where

import HabitOfFate.Prelude

import Control.Monad.Catch (MonadThrow)
import Control.Monad.Random (MonadRandom, uniform)

import HabitOfFate.Data.Markdown
import HabitOfFate.Data.QuestState
import HabitOfFate.Quest
import HabitOfFate.Substitution
import qualified HabitOfFate.Quests.Forest as Forest

quests ∷ [Quest Story]
quests =
  [ Forest.quest
  ]

randomQuestState ∷ (MonadRandom m, MonadThrow m) ⇒ m (QuestState Markdown)
randomQuestState =
  uniform quests
  >>=
  \quest →
    randomQuestStateFor quest
    >>=
    traverse (substitute (quest & quest_standard_substitutions))

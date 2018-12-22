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

{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UnicodeSyntax #-}

module HabitOfFate.Data.Habit where

import HabitOfFate.Prelude

import Control.DeepSeq (NFData)
import Control.Monad.Catch

import Data.Aeson
import Data.Time.LocalTime (LocalTime)
import Data.UUID

import GHC.Generics (Generic)

import Text.Blaze (ToMarkup(..))
import Web.Scotty (Parsable(..))

import HabitOfFate.Data.Repeated
import HabitOfFate.Data.Scale
import HabitOfFate.TH

newtype Difficulty = Difficulty { unwrapDifficulty ∷ Scale }
  deriving (Bounded,Enum,Eq,FromJSON,Generic,NFData,Ord,ToJSON)

instance Wrapped Difficulty where
  type Unwrapped Difficulty = Scale
  _Wrapped' = iso unwrapDifficulty Difficulty

instance Show Difficulty where
  show = showScale "Difficulty"

instance ToMarkup Difficulty where
  toMarkup = toMarkupScale "Difficulty"

instance Read Difficulty where
  readsPrec = readPrecsScale "Difficulty"

instance Parsable Difficulty where
  parseParam = parseParamScale "Difficulty"

newtype Importance = Importance { unwrapImportance ∷ Scale }
  deriving (Bounded,Enum,Eq,FromJSON,Generic,NFData,Ord,ToJSON)

instance Wrapped Importance where
  type Unwrapped Importance = Scale
  _Wrapped' = iso unwrapImportance Importance

instance Show Importance where
  show = showScale "Importance"

instance ToMarkup Importance where
  toMarkup = toMarkupScale "Importance"

instance Read Importance where
  readsPrec = readPrecsScale "Importance"

instance Parsable Importance where
  parseParam = parseParamScale "Importance"

data Frequency =
    Indefinite
  | Once (Maybe LocalTime)
  | Repeated DaysToKeep LocalTime Repeated
  deriving (Eq, Generic, NFData, Read, Show, Ord)
deriveJSON ''Frequency

instance Default Frequency where
  def = Indefinite

data Habit = Habit
  { _name_ ∷ Text
  , _difficulty_ ∷ Difficulty
  , _importance_ ∷ Importance
  , _frequency_ ∷ Frequency
  , _group_membership_ ∷ Set UUID
  , _maybe_last_marked_ ∷ Maybe LocalTime
  } deriving (Eq,Generic,NFData,Ord,Read,Show)
deriveJSON ''Habit

name_ ∷ Lens' Habit Text
name_ = lens _name_ (\old new_name → old { _name_ = new_name })

difficulty_, importance_ ∷ Lens' Habit Scale
difficulty_ =
  lens
    (_difficulty_ >>> unwrapDifficulty)
    (\old new_scale → old { _difficulty_ = Difficulty new_scale })
importance_ =
  lens
    (_importance_ >>> unwrapImportance)
    (\old new_scale → old { _importance_ = Importance new_scale })

frequency_ ∷ Lens' Habit Frequency
frequency_ = lens _frequency_ (\old new_frequency → old { _frequency_ = new_frequency })

group_membership_ ∷ Lens' Habit (Set UUID)
group_membership_ = lens _group_membership_ (\old new_group_membership → old { _group_membership_ = new_group_membership })

maybe_last_marked_ ∷ Lens' Habit (Maybe LocalTime)
maybe_last_marked_ = lens _maybe_last_marked_ (\old new_maybe_last_marked → old { _maybe_last_marked_ = new_maybe_last_marked })

getHabitDeadline ∷ Habit → Maybe LocalTime
getHabitDeadline =
  (^. frequency_)
  >>>
  (\case
    Once maybe_deadline → maybe_deadline
    Repeated _ deadline _ → Just deadline
    Indefinite → Nothing
  )

instance Default Habit where
  def = Habit "" (Difficulty def) (Importance def) def mempty Nothing

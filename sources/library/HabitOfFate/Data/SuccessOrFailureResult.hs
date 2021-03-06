{-
    Habit of Fate, a game to incentivize habit formation.
    Copyright (C) 2018 Gregory Crosswhite

    This program is free software: you can redistribute it and/or modify
    it under version 3 of the terms of the GNU Affero General Public License.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
-}

{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UnicodeSyntax #-}

module HabitOfFate.Data.SuccessOrFailureResult where

import HabitOfFate.Prelude

import Data.Aeson (FromJSON(..), ToJSON(..), Value(String), withText)

data SuccessOrFailureResult = SuccessResult | FailureResult deriving (Enum, Eq, Read, Show, Ord)

instance ToJSON SuccessOrFailureResult where
  toJSON SuccessResult = String "success"
  toJSON FailureResult = String "failure"

instance FromJSON SuccessOrFailureResult where
  parseJSON = withText "success/failure result value must have string shape" $ \case
    "success" → pure SuccessResult
    "failure" → pure FailureResult
    other → fail [i|not success or failure: #{other}|]

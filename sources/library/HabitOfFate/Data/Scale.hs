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

{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UnicodeSyntax #-}

module HabitOfFate.Data.Scale where

import HabitOfFate.Prelude

import Control.DeepSeq (NFData(..))
import Data.Aeson (FromJSON(..), ToJSON(..), Value(String), withText)
import qualified Data.Text.Lazy as Lazy
import Text.Blaze (Markup, ToMarkup(..))
import Web.Scotty (Parsable(..))

data Scale = None | VeryLow | Low | Medium | High | VeryHigh
  deriving (Bounded,Enum,Eq,Ord,Read,Show)

instance ToJSON Scale where
  toJSON None = String "none"
  toJSON VeryLow = String "very low"
  toJSON Low = String "low"
  toJSON Medium = String "medium"
  toJSON High = String "high"
  toJSON VeryHigh = String "very high"

instance FromJSON Scale where
  parseJSON = withText "scale value must have string shape" $ \case
    "none" → pure None
    "very low" → pure VeryLow
    "low" → pure Low
    "medium" → pure Medium
    "high" → pure High
    "very high" → pure VeryHigh
    other → fail [i|unsupported scale: #{other}|]

instance NFData Scale where rnf !_ = ()

instance Default Scale where def = Medium

instance Parsable Scale where
  parseParam p =
    p
    |> unpack
    |> readMaybe
    |> maybe (Left $ "Unrecognized scale \"" ⊕ p ⊕ "\".") Right

instance ToMarkup Scale where
  toMarkup = displayScale >>> toMarkup

scales ∷ [Scale]
scales = enumFromTo minBound maxBound

displayScale ∷ Scale → Text
displayScale None = "None"
displayScale VeryLow = "Very Low"
displayScale Low = "Low"
displayScale Medium = "Medium"
displayScale High = "High"
displayScale VeryHigh = "Very High"

showScale ∷ (Wrapped α, Unwrapped α ~ Scale) ⇒ String → α → String
showScale name =
  (^. _Wrapped')
  >>>
  show
  >>>
  (⊕ name)

toMarkupScale ∷ (Wrapped α, Unwrapped α ~ Scale) ⇒ Text → α → Markup
toMarkupScale name =
  (^. _Wrapped')
  >>>
  displayScale
  >>>
  (\scale_str → scale_str ⊕ " " ⊕ name)
  >>>
  toMarkup

readPrecsScale ∷ (Wrapped α, Unwrapped α ~ Scale) ⇒ String → Int → String → [(α, String)]
readPrecsScale name p =
  readsPrec p
  >>>
  \case
    [(scale, rest)]
      | rest == name → [(scale ^. _Unwrapped', "")]
      | otherwise → []
    _ → []

parseParamScale ∷ (Wrapped α, Unwrapped α ~ Scale) ⇒ Lazy.Text → Lazy.Text → Either Lazy.Text α
parseParamScale name p =
  case words p of
    [scale_text, name_]
      | name_ == name →
          parseParam scale_text
          |> bimap
              (\error_message →
                 "Error parsing scale \"" ⊕ scale_text ⊕ "\" in \"" ⊕ p ⊕ "\": " ⊕ error_message)
              (^. _Unwrapped')
      | otherwise → Left $ "Second word in \"%" ⊕ p ⊕ "\" was not " ⊕ name
    _ → Left $ "Wrong number of words in \"" ⊕ p ⊕ "\""

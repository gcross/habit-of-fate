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

{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE UnicodeSyntax #-}

module HabitOfFate.Story.Renderer.XML (renderEventToXMLText) where

import HabitOfFate.Prelude hiding (Element)

import qualified Data.Text.Lazy as Lazy
import Text.XML

import HabitOfFate.Story
import HabitOfFate.Substitution

renderParagraphToNodes ∷ HashMap Text Gendered → Paragraph → [Node]
renderParagraphToNodes substitutions paragraph =
  case recurse paragraph of
    [] → []
    nodes → [NodeElement $ Element "p" mempty nodes]
  where
    recurse ∷ Paragraph → [Node]
    recurse (StyleP style p)
      | null nested = []
      | otherwise =
          let tag = case style of
                Bold → "b"
                Underline → "u"
                Color Red → "red"
                Color Blue → "blue"
                Color Green → "green"
                Introduce → "introduce"
          in Element tag mempty nested |> NodeElement |> singleton
      where
        nested = recurse p
    recurse (MergedP children) = concatMap recurse children
    recurse (SubstitutionP substitution) =
      lookupAndApplySubstitution substitutions substitution
      |> either (show >>> error) (NodeContent >>> (:[]))
    recurse (TextP t) = [NodeContent t]

renderEventToElement ∷ HashMap Text Gendered → Event → Element
renderEventToElement substitutions =
  concatMap (renderParagraphToNodes substitutions)
  >>>
  Element "event" mempty

renderEventToNode ∷ HashMap Text Gendered → Event → Node
renderEventToNode substitutions =
  renderEventToElement substitutions
  >>>
  NodeElement

renderEventToDocument ∷ HashMap Text Gendered → Event → Document
renderEventToDocument substitutions =
  renderEventToElement substitutions
  >>>
  (\n → Document (Prologue [] Nothing []) n [])

renderEventToXMLText ∷ HashMap Text Gendered → Event → Lazy.Text
renderEventToXMLText substitutions =
  renderEventToDocument substitutions
  >>>
  renderText def

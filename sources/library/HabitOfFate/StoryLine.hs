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
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE UnicodeSyntax #-}

module HabitOfFate.StoryLine where

import HabitOfFate.Prelude

import Control.Monad.Catch (MonadThrow(throwM),Exception)
import Data.Traversable (Traversable(traverse))

import HabitOfFate.Data.Markdown
import HabitOfFate.Data.Outcomes
import HabitOfFate.Story
import HabitOfFate.Substitution

data ShuffleMode = Shuffle | NoShuffle deriving (Enum,Eq,Ord,Read,Show)

data Entry content =
    EventEntry
      { event_name ∷ Text
      , event_outcomes ∷ Outcomes content
      , event_random_stories ∷ [content]
      }
  | NarrativeEntry
      { narrative_name ∷ Text
      , narrative_content ∷ Narrative content
      }
  | LineEntry
      { line_shuffle_mode ∷ ShuffleMode
      , line_name ∷ Text
      , line_contents ∷ [Entry content]
      }
  | SplitEntry
      { split_name ∷ Text
      , split_story ∷ Narrative content
      , split_question ∷ Markdown
      , split_branches ∷ [Branch content]
      }
 deriving (Eq,Foldable,Functor,Ord,Read,Show,Traversable)

data DeadEnd = DeadEnd deriving (Eq,Show)
instance Exception DeadEnd where

nextPathOf ∷ MonadThrow m ⇒ Entry content → m Text
nextPathOf EventEntry{..} = pure $ event_name ⊕ "/common"
nextPathOf NarrativeEntry{..} = pure $ narrative_name
nextPathOf LineEntry{..} = case line_contents of
  [] → throwM DeadEnd
  entry:_ → ((line_name ⊕ "/") ⊕) <$> nextPathOf entry
nextPathOf SplitEntry{..} = pure $ split_name ⊕ "/common"

data Branch content = Branch
  { branch_choice ∷ Markdown
  , branch_fames ∷ [content]
  , branch_entry ∷ Entry content
  } deriving (Eq,Foldable,Functor,Ord,Read,Show,Traversable)

data Quest content = Quest
  { quest_name ∷ Text
  , quest_choice ∷ Markdown
  , quest_fames ∷ [content]
  , quest_standard_substitutions ∷ Substitutions
  , quest_entry ∷ Entry content
  } deriving (Eq,Foldable,Functor,Ord,Read,Show,Traversable)

substituteQuest ∷ MonadThrow m ⇒ Substitutions → Quest Story → m (Quest Markdown)
substituteQuest subs = traverse (substitute subs)

substituteQuestWithStandardSubstitutions ∷ MonadThrow m ⇒ Quest Story → m (Quest Markdown)
substituteQuestWithStandardSubstitutions quest@Quest{..} = substituteQuest quest_standard_substitutions quest

initialQuestPath ∷ MonadThrow m ⇒ Quest content → m Text
initialQuestPath Quest{..} = ((quest_name ⊕ "/") ⊕) <$> nextPathOf quest_entry

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

{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UnicodeSyntax #-}

module HabitOfFate.Quests.Forest where

--------------------------------------------------------------------------------
----------------------------------- Imports ------------------------------------
--------------------------------------------------------------------------------

import HabitOfFate.Prelude hiding (State)

import Control.Monad.Catch (MonadThrow)
import Control.Monad.Random (uniform)
import System.Random.Shuffle

import HabitOfFate.Data.Tagged
import HabitOfFate.Quest
import qualified HabitOfFate.Quest.StateMachine as StateMachine
import HabitOfFate.Quest.StateMachine (Transition(..))
import HabitOfFate.Substitution
import HabitOfFate.Story
import HabitOfFate.Pages
import HabitOfFate.TH

import HabitOfFate.Quests.Forest.Stories

--------------------------------------------------------------------------------
------------------------------------ Types -------------------------------------
--------------------------------------------------------------------------------

data SearcherType = Parent | Healer deriving (Eq,Ord,Read,Show)
deriveJSON ''SearcherType

data Event = GingerbreadHouseEvent | FoundEvent | FairyCircleEvent | HomeEvent
  deriving (Bounded,Enum,Eq,Ord,Read,Show)
deriveJSON ''Event

data Internal = Internal
  { searcher_type ∷ SearcherType
  , event_order ∷ [Event]
  } deriving (Eq,Ord,Read,Show)
deriveJSON ''Internal

data Label = GingerbreadHouse | FoundByCat | FoundByFairy | FairyCircle | Home
  deriving (Bounded,Enum,Eq,Ord,Read,Show)
deriveJSON ''Label

type State = StateMachine.State Label Internal

static_substitutions ∷ Substitutions
static_substitutions =
  mapFromList
    [ ( "", Gendered "Bobby" Male )
    , ( "Searcher", Gendered "Bobby" Male )
    , ( "Child", Gendered "Mary" Female )
    , ( "Plant", Gendered "Tigerlamp" Neuter )
    , ( "catcolor", Gendered "yellow" Neuter )
    ]

--------------------------------------------------------------------------------
------------------------------------ Logic -------------------------------------
--------------------------------------------------------------------------------

transitionsFor ∷ Internal → [(Label, Transition Label)]
transitionsFor Internal{..} =
  case event_order of
    [] → error "There should have been at least one event present."
    (first:rest) → concatMap (uncurry eventToTransitions) $ go first rest
 where
  go ∷ Event → [Event] → [(Event, [Label])]
  go current [] = (current, [Home]):(HomeEvent, []):[]
  go current (next:rest) = (current, next_labels):go next rest
    where
    next_labels = case next of
      GingerbreadHouseEvent → [GingerbreadHouse]
      FoundEvent → [FoundByFairy, FoundByCat]
      FairyCircleEvent → [FairyCircle]
      HomeEvent → [Home]

  eventToTransitions ∷ Event → [Label] → [(Label, Transition Label)]
  eventToTransitions GingerbreadHouseEvent next_labels =
    [ ( GingerbreadHouse
      , Transition gingerbread_house wander_stories looking_for_herb_story next_labels def
      )
    ]
  eventToTransitions FoundEvent next_labels =
    [ ( FoundByCat
      , Transition found_by_cat wander_stories looking_for_herb_story next_labels
          (Tagged (Success [("catcolor", Gendered "green" Neuter)])
                  (Failure [("catcolor", Gendered "blue" Neuter)])
          )
      )
    , ( FoundByFairy
      , Transition found_by_fairy wander_stories returning_home_story next_labels def
      )
    ]
  eventToTransitions FairyCircleEvent next_labels =
    [ ( FairyCircle
      , Transition fairy_circle wander_stories returning_home_story next_labels def
      )
    ]
  eventToTransitions HomeEvent next_labels =
    [ ( Home
      , Transition conclusion wander_stories returning_home_story [] def
      )
    ]

  conclusion = case searcher_type of
    Parent → conclusion_parent
    Healer → conclusion_healer

initialize ∷ InitializeQuestRunner State
initialize = do
  searcher_type ← uniform [Parent, Healer]
  event_order ← shuffleM [GingerbreadHouseEvent, FoundEvent, FairyCircleEvent]
  first_label ← case event_order ^?! _head of
    GingerbreadHouseEvent → pure GingerbreadHouse
    FoundEvent → uniform [FoundByCat, FoundByFairy]
    FairyCircleEvent → pure FairyCircle
    _ → error "unexpected element in event order"
  let introduction = case searcher_type of
        Parent → intro_parent_story
        Healer → intro_healer_story
  StateMachine.initialize static_substitutions first_label Internal{..} introduction

getStatus ∷ GetStatusQuestRunner State
getStatus s = StateMachine.getStatus (s |> StateMachine.internal |> transitionsFor) s

trial ∷ TrialQuestRunner State
trial result scale = do
  transitions ← get <&> (StateMachine.internal >>> transitionsFor)
  StateMachine.trial transitions result scale

--------------------------------------------------------------------------------
--------------------------------- Proofreading ---------------------------------
--------------------------------------------------------------------------------

pages ∷ MonadThrow m ⇒ m Pages
pages = buildPages
  (mapFromList
    [ ( "", Gendered "Andrea" Female )
    , ( "Searcher", Gendered "Andrea" Female )
    , ( "Child", Gendered "Elly" Female )
    , ( "Plant", Gendered "Tigerlamp" Neuter )
    ]
  )
  ( PageGroup "forest"
    [ PageItem
        ""
        "Searching For An Essential Ingredient In The Wicked Forest"
        intro_healer_story
        (NoChoice "gingerbread")
    , PageGroup "gingerbread"
      [ PageItem
          ""
          "The Gingerbread House"
          (gingerbread_house ^. story_common_)
          (Choices "Where do you guide Andrea?"
            [("Towards the gingerbread house.",  "towards")
            ,("Away from the gingerbread house.", "away")
            ]
          )
      , PageItem
          "away"
          "Even Gingerbread Cannot Slow Her Search"
          (gingerbread_house ^. story_success_)
          (NoChoice "-forest-found")
      , PageItem
          "towards"
          "The Gingerbread Compulsion is Too Great"
          (gingerbread_house ^. story_averted_or_failure_)
          (Choices "How do you have Andrea react?"
            [("She enters the house.", "enter")
            ,("She runs away!", "run")
            ]
          )
      , PageItem
          "enter"
          "Entering The Gingerbread House"
          (gingerbread_house ^. story_failure_)
          DeadEnd
      , PageItem
          "run"
          "Escaping The Gingerbread House"
          (gingerbread_house ^. story_averted_)
          (NoChoice "-forest-found")
      ]
    , PageItem
        "found"
        "The Ingredient Is Finally Found... Or Is It?"
        "Test found page."
        DeadEnd
    ]
  )

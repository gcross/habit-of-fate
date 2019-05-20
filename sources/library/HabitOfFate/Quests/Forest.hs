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

import Control.Monad.Random (getRandomR, uniform)
import Data.Vector (Vector)
import qualified Data.Vector as V

import HabitOfFate.Data.SuccessOrFailureResult
import HabitOfFate.Data.Tagged
import HabitOfFate.Quest
import qualified HabitOfFate.Quest.StateMachine as StateMachine
import HabitOfFate.Quest.StateMachine (Transition(..))
import HabitOfFate.Story
import HabitOfFate.Substitution
import HabitOfFate.TH

import HabitOfFate.Quests.Forest.Stories

--------------------------------------------------------------------------------
------------------------------------ Types -------------------------------------
--------------------------------------------------------------------------------

data SearcherType = Parent | Healer deriving (Bounded,Enum,Eq,Ord,Read,Show)
deriveJSON ''SearcherType

data Event = GingerbreadHouseEvent | FoundEvent | FairyCircleEvent | HomeEvent
  deriving (Bounded,Enum,Eq,Ord,Read,Show)
deriveJSON ''Event

data Internal = Internal
  { searcher_type ∷ SearcherType
  , child ∷ Gendered
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

  dup ∷ α → Tagged α
  dup x = Tagged (Success x) (Failure x)

  eventToTransitions ∷ Event → [Label] → [(Label, Transition Label)]
  eventToTransitions GingerbreadHouseEvent next_labels =
    [ ( GingerbreadHouse
      , Transition gingerbread_house wander_stories looking_for_herb_story (dup next_labels) def []
      )
    ]
  eventToTransitions FoundEvent next_labels =
    [ ( FoundByCat
      , Transition found_by_cat wander_stories looking_for_herb_story (dup next_labels)
          (Tagged (Success [("catcolor", Gendered "green" Neuter)])
                  (Failure [("catcolor", Gendered "blue" Neuter)])
          )
          []
      )
    , ( FoundByFairy
      , Transition found_by_fairy wander_stories returning_home_story (dup next_labels) def []
      )
    ]
  eventToTransitions FairyCircleEvent next_labels =
    [ ( FairyCircle
      , Transition fairy_circle wander_stories returning_home_story (dup next_labels) def []
      )
    ]
  eventToTransitions HomeEvent next_labels =
    [ ( Home
      , Transition conclusion wander_stories returning_home_story (dup []) def fames_parent
      )
    ]

  conclusion = case searcher_type of
    Parent → conclusion_parent
    Healer → conclusion_healer

plants ∷ [Text]
plants =
  ["Illsbane"
  ,"Tigerlamp"
  ]

initialize ∷ InitializeQuestRunner State
initialize = do
  searcher_type ← chooseFromAll
  searcher ← allocateAny
  child ← allocateAny
  plant ← chooseFrom plants
  let substitutions = mapFromList
        [("", searcher)
        ,("Searcher", searcher)
        ,("Child", child)
        ,("Plant", Gendered plant Neuter)
        ]
  event_order ← shuffleFrom [GingerbreadHouseEvent, FoundEvent, FairyCircleEvent]
  first_label ← case event_order ^?! _head of
    GingerbreadHouseEvent → pure GingerbreadHouse
    FoundEvent → chooseFrom [FoundByCat, FoundByFairy]
    FairyCircleEvent → pure FairyCircle
    _ → error "unexpected element in event order"
  let introduction = case searcher_type of
        Parent → intro_parent
        Healer → intro_healer
  StateMachine.initialize substitutions first_label Internal{..} (introduction & narrative_story)

getStatus ∷ GetStatusQuestRunner State
getStatus =
  (ask <&> (StateMachine.internal >>> transitionsFor))
  >>=
  StateMachine.getStatus

trial ∷ TrialQuestRunner State
trial result = do
  internal@Internal{..} ← get <&> StateMachine.internal
  let transitions = transitionsFor internal
  outcome ← StateMachine.trial transitions result
  pure outcome

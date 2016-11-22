{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UnicodeSyntax #-}

module HabitOfFate.Quests.Forest where

import Control.Lens ((&), (^.), (+=), (.~), makeLenses)
import Data.Map (fromList)
import Data.String.QQ

import HabitOfFate.Game
import HabitOfFate.Substitution
import HabitOfFate.TH
import HabitOfFate.Unicode

data State = State
  { _healer ∷ Character
  , _patient ∷ Character
  , _herb ∷ String
  , _found ∷ Bool
  } deriving (Eq,Ord,Read,Show)
deriveJSON ''State
makeLenses ''State

defaultSubstitutionTable ∷ State → Substitutions
defaultSubstitutionTable forest_state = makeSubstitutionTable
  [("Susie",forest_state ^. healer)
  ,("Tommy",forest_state ^. patient)
  ,("Illsbane",Character (forest_state ^. herb) Neuter)
  ]

textWithDefaultSubtitutionsPlus ∷ State → [(String,String)] → String → Game ()
textWithDefaultSubtitutionsPlus forest_state additional_subsitutions =
    text . substitute substitutions
  where
    substitutions =
      defaultSubstitutionTable forest_state
      ⊕
      fromList additional_subsitutions

textWithDefaultSubtitutions ∷ State → String → Game ()
textWithDefaultSubtitutions = flip textWithDefaultSubtitutionsPlus []

new :: Game State
new = do
  let state = State
        (Character "Susie" Female)
        (Character "Tommy" Male)
        "Illsbane"
        False
  introText state
  return state

act :: GameInput → State → Game (Maybe State)
act Good state = weightedAction
  [(20, if state ^. found
    then do
      winText state
      belief += 1
      return Nothing
    else do
      foundText state
      return . Just $ state & found .~ True
    )
  ,(80, do
      stumbleText state
      return $ Just state
    )
  ]
act Bad state = weightedAction
  [(50, do
    fallText state
    return $ Just state
    )
  ,(50, do
    loseText state
    return Nothing
    )
  ]

fallText state = textWithDefaultSubtitutions state [s|
  {She} trips and falls, but gets up after minute.
|]

foundText state = textWithDefaultSubtitutions state [s|
  After wandering for what feels like hours, {Susie} nearly steps on {an
  Illsbane} plant. {Her} heart leaps and {she} gives a short prayer of thanks.
  {She} reaches down carefully to pick it.

  Now {she} just needs to find {her} way back to the village, but she is hopeful
  -- you have guided {her} this far, after all!
|]

introText state = textWithDefaultSubtitutions state [s|
  The last thing in the world that {Susie} wanted to do was to wander around
  alone in the forest this night, but {Tommy} was sick and would not live
  through the night unless {Susie} could find {an Illsbane} plant to brew
  medicine for {him|Tommy}.

  She begins her search.|]

loseText state = textWithDefaultSubtitutions state [s|
  {She} takes too long, and {Tommy} dies}.
|]

stumbleText state = textWithDefaultSubtitutions state [s|
  {She} stumbles around in the dark.
|]

winText state = textWithDefaultSubtitutions state [s|
  {Susie} is starting to feel like {she} will never make it back when she
  notices that things are starting to get brighter -- {she} must be getting
  close to the vilage! {She} gives you thanks for guiding {her} home.

  A little bit further, and {she} is back to her house. Without a moment to
  spare, {she} immediately starts brewing medicine for {Tommy}! {She} brings the
  medicine to {Tommy}, and wakes him up long enough to ladel it down his throat.
  {He|Tommy} immediately falls back asleep. As {Susie} is filled with relief,
  exhaustion catches up to her and {she} falls asleep on the floor.

  {She} sleeps peacefully, with a smile on her face. The next day, she builds an
  alter to you out of gratitude.

  Well done!
|]

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

import HabitOfFate.Credits
import HabitOfFate.Game
import HabitOfFate.Quest
import HabitOfFate.Story
import HabitOfFate.Story.Parser.Quote
import HabitOfFate.Story.Substitution
import HabitOfFate.TH
import HabitOfFate.Trial

--------------------------------------------------------------------------------
------------------------------------ Types -------------------------------------
--------------------------------------------------------------------------------

data State = State
  { _gendered_substitutions_ ∷ HashMap Text Gendered
  , _neutered_substitutions_ ∷ HashMap Text Text
  , _herb_found_ ∷ Bool
  , _credits_until_success_ ∷ Double
  , _credits_until_failure_ ∷ Double
  } deriving (Eq,Ord,Read,Show)
deriveJSON ''State
makeLenses ''State

type ForestAction = QuestAction State

--------------------------------------------------------------------------------
-------------------------------- Text Functions --------------------------------
--------------------------------------------------------------------------------

storyForState ∷ MonadGame m ⇒ State → SubEvent → m ()
storyForState forest event =
  substituteAndAddParagraphs
    (forest ^. gendered_substitutions_)
    (forest ^. neutered_substitutions_)
    (event ^.. paragraphs)

storyForLens ∷ (MonadState s m, MonadGame m) ⇒ Lens' s State → SubEvent → m ()
storyForLens lens template = use lens >>= \forest → storyForState forest template

questStory ∷ SubEvent → ForestAction ()
questStory = storyForLens quest_

randomQuestStory ∷ [SubEvent] → ForestAction ()
randomQuestStory = fmap questStory >>> uniformAction

--------------------------------------------------------------------------------
------------------------------------ Intro -------------------------------------
--------------------------------------------------------------------------------

intro_story = [s_fixed|
================================================================================
The last thing in the world that <introduce>{Susie}</introduce> wanted to do was
to wander alone in the Wicked Forest at night, but {her|pos} {son}, little
<introduce>{Tommy}</introduce>, was sick and would not live through the night
unless {Susie} could find <introduce>{an Illsbane}</introduce> plant. It is a
hopeless task, but {she} has no other choice.
================================================================================
|]

new ∷ Game State
new =
  (
    State
      (mapFromList
        [ ("Susie", Gendered "Sally" Female)
        , ("Tommy", Gendered "Billy" Female)
        ]
      )
      (mapFromList
        [ ("Illsbane", "Rootsbane")
        ]
      )
      False
    <$> numberUntilEvent 5
    <*> numberUntilEvent 1
  )
  >>=
  execStateT (storyForLens identity intro_story)

--------------------------------------------------------------------------------
------------------------------------- Lost -------------------------------------
--------------------------------------------------------------------------------

data FailureResult = FailureAverted | FailureHappened

data FailureEvent = FailureEvent
  { _common_failure_event_ ∷ SubEvent
  , _failure_averted_event_ ∷ SubEvent
  , _failure_happened_event_ ∷ SubEvent
  }
makeLenses ''FailureEvent

lost ∷ ForestAction ()
lost = do
  uniform failure_stories >>= runFailureEvent FailureHappened
  questHasEnded

averted ∷ ForestAction ()
averted = uniform failure_stories >>= runFailureEvent FailureAverted

runFailureEvent ∷ FailureResult → FailureEvent → ForestAction ()
runFailureEvent failure_result event = do
  questStory $ event ^. common_failure_event_
  (questStory <<< (event ^.)) $
    case failure_result of
      FailureAverted → failure_averted_event_
      FailureHappened → failure_happened_event_

makeFailureEvent (common,averted,happened) = FailureEvent common averted happened

failure_stories ∷ [FailureEvent]
failure_stories = fmap makeFailureEvent
------------------------------ Gingerbread House -------------------------------
  [[s_fixed|
================================================================================
{Susie} sees a house made out of... gingerbread?

{She} feels a strange compulsion to approach it.
================================================================================
{She} fights the compulsion, and continues on {her|pos} search.
================================================================================
As {she} gets closer, the door opens and an old woman beckons {her|obj} in.
“You've arrived just in time!” she says. “Dinner has just finished cooking. Come
on in!”

Not knowing why {she} was doing this, {Susie} entered the... cottage? The woman
leads {her|obj} to an oven. “Here, look inside.”

{Susie} looks inside the oven and sees... little {Tommy}? {She} screams, and
faints.

Daylight awakens {her|obj}. {She} looks around, but the gingerbread house is
nowhere to be found.

{She} sobs -- there is no way that {she} will be able to make it home in time
now.
================================================================================
     |]
  ]

--------------------------------------------------------------------------------
------------------------------------ Wander ------------------------------------
--------------------------------------------------------------------------------

wander_stories = [s|
================================================================================
Nothing happens as {Susie} wanders through the forest.
================================================================================
As {Susie} continues to search {she} hears wolves howling in the distance, which
makes {her|obj} shiver. Thank goodness they seem to be in the distance.
================================================================================
{Susie} is paying so much attention to looking for {Illsbane} that {she} almost
misses the ominous circle of mushrooms. {She} says a prayer of thanks that {she}
noticed it before stepping inside.
================================================================================
{Susie} starts to notice that it is growing brighter. {She} looks around and
sees an unnaturally glowing clearing in the distance. {She} feels drawn to it,
but {she} knows that no good could possibly come to {her|obj} there, so {she}
summons her will and turns away from it.
================================================================================
{Susie}'s candle goes out; the resulting darkness is oppressive. Fortunately,
{she} prepared for this. {She} reached into {her|pos} pack and drew out
flintstone, which {she} uses to re-light the candle.
================================================================================
{Susie} can feel that something is amiss, but {she} can't figure out what. {She}
pauses for a moment and looks around. After a moment, {she} realizes that
{her|pos} shadow didn't stop walking when {she} did. {She} backs away slowly as
{her|pos} shadow gets further and further away from {her|obj}. {She} decide to
start searching in a different direction.
================================================================================
{Susie} trips on a branch and nearly falls. “Odd,” {she} says to {herself},
“I've been staring at the ground; how could I have missed it?” Examining the
ground more closely, {she} sees the root {she} tripped on lower itself back into
the earth. {She} then catches another one rising right next to her. {She} tries
backing away slowly, but then nearly trips on a root behind {her|obj}. {She}
breaks into a run, leaping with each step so that {her|pos} feet cannot be
caught. {She} hears the rustling of leaves in the wind and it sounds like
laughter.
================================================================================
{Susie} hears rustling in the leaves and turns to face it. {She} sees a mouse
emerge, looking around for signs of danger. {Susie} lets out the breath that
{she} had just realized {she} was holding.

“Human, what are you doing in the forest?” {she} hears it ask.

{Susie} jumps. {She} starts to answer, but then {she} sees a blur dive towards
the mouse, grab it, and then head back towards the sky; after a moment of
staring {she} realizes that it is an owl. The screams of the mouse for help die
away as the owl flies off.

{She} resumes {her|pos} search, shaken by what had just happened.
================================================================================
{Susie} looks up at the Moon. For reasons that nobody understands, the Moon is
always full in the Wicked Forest. The good news is that this makes it easier to
search for {Illsbane}, but the bad news is that {she} has to worry about
werewolves...
================================================================================
“Hello, human. It isn't often that I get to see one of your kind here.”

{Susie} jumped and looked around for the source of the voice. {She} heard it
laugh. “You are just as stupid as the rest of your kind. Look, I am over here.”

{Susie} finally realized that the voice was coming from the tree right next to
{her|obj}.

“Why are you here?” it asked. {Susie} replied, “I am looking for an {Illsbane}
plant. I down't suppose you have seen one?” It laughed. “Do I look like I have
legs?” {Susie} replied, “Umm, no, I guess not; I guess I'll just be going on my
way then...”

{Susie} resumed searching, the laugher of the tree receding as {she} left it
behind.
================================================================================
{Susie} finally sees an {Illsbane} plant. {She} offers you a prayer of thanks,
and then reaches down to pick it.

Suddenly, it changes into the shape of a creature with a head, three arms, and
three legs. It makes a noise that mixes shrieking with laughter, and then runs
off.

{Susie} bows {her|pos} head in shock and disappointment, and resumes searching.
|]

--------------------------------------------------------------------------------
------------------------------------ Found -------------------------------------
--------------------------------------------------------------------------------

found_stories = [s|
================================================================================

After searching for what feels like hours, {Susie} nearly steps on an {Illsbane}
plant. {Her} heart leaps and {she} gives a short prayer of thanks. {She}
reaches down carefully to pick it up, and then starts heading back to {her|pos}
home.

================================================================================

{Susie} starts to hear a sound and {she} can't tell whether it is a buzzing or
the most beautiful music {she} has ever heard. As it gets louder {she} notices
the area around her starting to get brighter. {She} looks around and sees a
fairy, glowing brightly in the dark. The fairy beckons to {her|obj}, and then
flies away. {Susie} hesitates briefly, and then runs after the fairy.

{Susie} chases the fairy for about an hour, starting to doubt whether this is
such a good idea, when the fairy stops. {She} catches up to it and sees {an
Illsbane} plant under it. Carefully, {she} reaches down and picks it. When she
looks up, the fairy is gone.

{She} falls to {her|pos} knees and thanks you for guiding {her|obj} to the plan.
{She} then gets up and starts heading back to {her|pos} home.

================================================================================
|]

--------------------------------------------------------------------------------
------------------------------------- Won --------------------------------------
--------------------------------------------------------------------------------

won_story = [s_fixed|
================================================================================
{Susie} is starting to feel like {she} will never make it back when {she}
notices that things are starting to get brighter -- {she} must be getting close
to the vilage! {She} gives you thanks for guiding {her|obj} home.

A little bit further, and {she} is back to {her|pos} house. Without a moment to
spare, {she} immediately starts brewing medicine for {Tommy}! {She} brings the
medicine to {Tommy}, and wakes {him} up long enough to ladel it down his throat.
{He} immediately falls back asleep. As {Susie} is filled with relief, exhaustion
catches up to {her|obj} and {she} falls asleep on the floor.

{She} sleeps peacefully, with a smile on {her|pos} face. The next day, {she}
builds an alter to you out of gratitude.
================================================================================
|]

--------------------------------------------------------------------------------
------------------------------------ Logic -------------------------------------
--------------------------------------------------------------------------------

found ∷ ForestAction ()
found = do
  randomQuestStory found_stories
  quest_ . herb_found_ .= True
  numberUntilEvent 5 >>= (quest_ . credits_until_success_ .=)

won ∷ ForestAction ()
won = questStory won_story >> questHasEnded

run ∷ ForestAction ()
run = do
  spendCredits
    (quest_ . credits_until_failure_)
    (game_ . credits_ . failures_)
    >>=
    \case
      SomethingHappened → lost
      NothingHappened → averted
      NoCredits → return ()
  spendCredits
    (quest_ . credits_until_success_)
    (game_ . credits_ . successes_)
    >>=
    \case
      SomethingHappened → (use $ quest_ . herb_found_) >>= bool found won
      NothingHappened → randomQuestStory wander_stories
      NoCredits → return ()

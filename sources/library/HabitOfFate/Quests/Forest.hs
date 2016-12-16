{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UnicodeSyntax #-}

module HabitOfFate.Quests.Forest where

--------------------------------------------------------------------------------
----------------------------------- Imports ------------------------------------
--------------------------------------------------------------------------------

import Control.Lens
import Control.Monad.State hiding (State)
import Data.Bool
import Data.List.Lens
import Data.List.Split
import Data.Map (fromList)
import Data.String.QQ

import HabitOfFate.Game
import HabitOfFate.Quest
import HabitOfFate.Substitution
import HabitOfFate.TH
import HabitOfFate.Trial
import HabitOfFate.Unicode
import Debug.Trace

--------------------------------------------------------------------------------
------------------------------------ Types -------------------------------------
--------------------------------------------------------------------------------

data State = State
  { _parent ∷ Character
  , _patient ∷ Character
  , _herb ∷ String
  , _herb_found ∷ Bool
  , _credits_until_success ∷ Double
  , _credits_until_failure ∷ Double
  } deriving (Eq,Ord,Read,Show)
deriveJSON ''State
makeLenses ''State

type ForestAction = QuestAction State

--------------------------------------------------------------------------------
-------------------------------- Text Functions --------------------------------
--------------------------------------------------------------------------------

defaultSubstitutionTable ∷ State → Substitutions
defaultSubstitutionTable forest = makeSubstitutionTable
  [("Susie",forest ^. parent)
  ,("Tommy",forest ^. patient)
  ,("Illsbane",Character (forest ^. herb) Neuter)
  ]

textWithDefaultSubstitutionsPlus ∷ MonadGame m ⇒ State → [(String,String)] → String → m ()
textWithDefaultSubstitutionsPlus forest additional_substitutions template =
  text
  ∘
  flip substitute template
  ∘
  (⊕ fromList additional_substitutions)
  ∘
  defaultSubstitutionTable
  $
  forest

textWithDefaultSubstitutionsForLens ∷ (MonadState s m, MonadGame m) ⇒ Lens' s State → String → m ()
textWithDefaultSubstitutionsForLens lens template =
  use lens
  >>=
  \forest → textWithDefaultSubstitutionsPlus forest [] template

forestText ∷ String → ForestAction ()
forestText = textWithDefaultSubstitutionsForLens quest ∘ stripEquals

forestTexts ∷ String → ForestAction ()
forestTexts = uniformAction ∘ map forestText ∘ splitTexts

startsWithEquals ∷ String → Bool
startsWithEquals = (== Just '=') ∘ (^? _head)

splitTexts ∷ String → [String]
splitTexts =
  filter (not ∘ null)
  ∘
  map unlines
  ∘
  split (condense ∘ dropDelims ∘ whenElt $ startsWithEquals)
  ∘
  lines

stripEquals ∷ String → String
stripEquals = unlines ∘ filter (not ∘ startsWithEquals) ∘ lines

--------------------------------------------------------------------------------
------------------------------------ Intro -------------------------------------
--------------------------------------------------------------------------------

introText = textWithDefaultSubstitutionsForLens id ∘ stripEquals

new ∷ Game State
new =
  (
    State
      (Character "Susie" Female)
      (Character "Tommy" Male)
      "Illsbane"
      False
    <$> numberUntilEvent 5
    <*> numberUntilEvent 1
  )
  >>=
  execStateT (introText [s|
================================================================================
The last thing in the world that {Susie} wanted to do was to wander alone in the
Wicked Forest at night, but her son, little {Tommy} was sick and would not live
through the night unless {Susie} could find {an Illsbane} plant. It is a
hopeless task, but she has no other choice.

She prays to you for a miracle, and then begins her search, carrying a candle to
light the way.
================================================================================
|])

--------------------------------------------------------------------------------
------------------------------------ Found -------------------------------------
--------------------------------------------------------------------------------

found ∷ ForestAction ()
found = do
  forestTexts found_texts
  quest . herb_found .= True
  numberUntilEvent 5 >>= (quest . credits_until_success .=)
  where
    found_texts = [s|
================================================================================

After searching for what feels like hours, {Susie} nearly steps on {an Illsbane}
plant. {Her} heart leaps and {she} gives a short prayer of thanks. {She} reaches
down carefully to pick it up, and then starts heading back to her home.

================================================================================

{Susie} starts to hear a sound and she can't tell whether it is a buzzing or the
most beautiful music she has ever heard. As it gets louder she notices the area
around her starting to get brighter. She looks around and sees a fairy, glowing
brightly in the dark. The fairy beckons to her, and then flies away. {Susie}
hesitates briefly, and then runs after the fairy.

{Susie} chases the fairy for about an hour, starting to doubt whether this is
such a good idea, when the fairy stops. She catches up to it and sees {an
Illsbane} plant under it. Carefully, she reaches down and picks it. When she
looks up, the fairy is gone.

{She} falls to her knees and thanks you for guiding her to the plan. {She} then
gets up and starts heading back to her home.

================================================================================
|]

--------------------------------------------------------------------------------
------------------------------------- Won --------------------------------------
--------------------------------------------------------------------------------

won ∷ ForestAction ()
won = do
  forestText won_text
  game . belief += 1
  questHasEnded
  where
    won_text = [s|
================================================================================
{Susie} is starting to feel like {she} will never make it back when she notices
that things are starting to get brighter -- {she} must be getting close to the
vilage! {She} gives you thanks for guiding {her} home.

A little bit further, and {she} is back to her house. Without a moment to spare,
{she} immediately starts brewing medicine for {Tommy}! {She} brings the medicine
to {Tommy}, and wakes him up long enough to ladel it down his throat. {He|Tommy}
immediately falls back asleep. As {Susie} is filled with relief, exhaustion
catches up to her and {she} falls asleep on the floor.

{She} sleeps peacefully, with a smile on her face. The next day, she builds an
alter to you out of gratitude.
================================================================================
|]

--------------------------------------------------------------------------------
------------------------------------- Lost -------------------------------------
--------------------------------------------------------------------------------

data FailureResult = FailureAverted | FailureHappened

data FailureStory = FailureStory
  { _common_failure_story ∷ String
  , _failure_averted_story ∷ String
  , _failure_happened_story ∷ String
  }
makeLenses ''FailureStory

lost ∷ ForestAction ()
lost = do
  uniform failure_stories >>= runFailureStory FailureHappened
  game . belief -= 1
  questHasEnded

averted ∷ ForestAction ()
averted = uniform failure_stories >>= runFailureStory FailureAverted

runFailureStory ∷ FailureResult → FailureStory → ForestAction ()
runFailureStory failure_result story = do
  forestText $ story ^. common_failure_story
  forestText ∘ (story ^.) $
    case failure_result of
      FailureAverted → failure_averted_story
      FailureHappened → failure_happened_story

makeFailureStory story = FailureStory common averted happened
  where
    [common,averted,happened] = splitTexts story

failure_stories ∷ [FailureStory]
failure_stories = map makeFailureStory
------------------------------ Gingerbread House -------------------------------
  [[s|
================================================================================
{Susie} sees a house made out of... gingerbread?

She feels a strange compulsion to approach it.
================================================================================
She fights the compulsion, and continues on her search.
================================================================================
As she gets closer, the door opens and an old woman beckons her in. “You've
arrived just in time!” she says. “Dinner has just finished cooking. Come on in!”

Not knowing why she was doing this, {Susie} entered the... cottage? The woman
leads her to an oven. “Here, look inside.”

{Susie} looks inside the oven and sees... little {Tommy}? She screams, and
faints.

Daylight awakens her. She looks around, but the gingerbread house is nowhere to
be found.

She sobs -- there is no way that she will be able to make it home in time now.
================================================================================
     |]
  ]

--------------------------------------------------------------------------------
------------------------------------ Wander ------------------------------------
--------------------------------------------------------------------------------

wander ∷ ForestAction ()
wander = forestTexts [s|
================================================================================
Nothing happens as {Susie} wanders through the forest.
================================================================================
As {Susie} continues to search she hears wolves howling in the distance, which
makes her shiver. Thank goodness they seem to be in the distance.
================================================================================
{Susie} is paying so much attention to looking for {Illsbane} that she almost
misses the ominous circle of mushrooms. {She} says a prayer of thanks that {she}
noticed it before stepping inside.
================================================================================
{Susie} starts to notice that it is growing brighter. She looks around and sees
an unnaturally glowing clearing in the distance. She feels drawn to it, but she
knows that no good could possibly come to her there, so she summons her will and
turns away from it.
================================================================================
{Susie}'s candle goes out; the resulting darkness is oppressive. Fortunately,
she prepared for this. She reached into her pack and drew out flintstone, which
she used to re-light the candle.
================================================================================
{Susie} can feel that something is amiss, but she can't figure out what. She
pauses for a moment and looks around. After a moment, she realizes that her
shadow didn't stop walking when she did. She backs away slowly as her shadow
gets further and further away from her. She decide to start searching in a
different direction.
================================================================================
{Susie} trips on a branch and nearly falls. “Odd,” she says to herself, “I've
been staring at the ground; how could I have missed it?” Examining the ground
more closely, she sees the root she tripped on lower itself back into the earth.
She then catches another one rising right next to her. She tries backing away
slowly, but then nearly trips on a root behind her. She breaks into a run,
leaping with each step so that her feet cannot be caught. She hears the rustling
of leaves in the wind and it sounds like laughter.
================================================================================
{Susie} hears rustling in the leaves and turns to face it. She sees a mouse
emerge, looking around for signs of danger. {Susie} lets out the breath that she
had just realized she was holding.

“Human, what are you doing in the forest?” she hears it ask.

{Susie} jumps. She starts to answer, but then she sees a blur dive towards the
mouse, grab it, and then head back towards the sky; after a moment of staring
she realizes that it is an owl. The screams of the mouse for help die away as
the owl flies off.

She resumes her search, shaken by what had just happened.
================================================================================
{Susie} looks up at the Moon. For reasons that nobody understands, the Moon is
always full in the Wicked Forest. The good news is that this makes it easier to
search for {Illsbane}, but the bad news is that she has to worry about
werewolves...
================================================================================
“Hello, human. It isn't often that I get to see one of your kind here.”

{Susie} jumped and looked around for the source of the voice. She heard it
laugh. “You are just as stupid as the rest of your kind. Look, I am over here.”

{Susie} finally realized that the voice was coming from the tree right next to
her.

“Why are you here?” it asked. {Susie} replied, “I am looking for an {Illsbane}
plant. I down't suppose you have seen one?” It laughed. “Do I look like I have
legs?” {Susie} replied, “Umm, no, I guess not; I guess I'll just be going on my
way then...”

{Susie} resumed searching, the laugher of the tree receding as she left it
behind.
================================================================================
{Susie} finally sees an {Illsbane} plant.  She offers you a prayer of thanks,
and then reaches down to pick it.

Suddenly, it changes into the shape of a creature with a head, three arms, and
three legs. It makes a noise that mixes shrieking with laughter, and then runs
off.

{Susie} bows her head in shock and disappointment, and resumes searching.
|]


--------------------------------------------------------------------------------
------------------------------------ Logic -------------------------------------
--------------------------------------------------------------------------------

run ∷ ForestAction ()
run = do
  spendCredits
    (quest . credits_until_failure)
    (game . failure_credits)
    >>=
    \case
      SomethingHappened → lost
      NothingHappened → averted
      NoCredits → return ()
  spendCredits
    (quest . credits_until_success)
    (game . success_credits)
    >>=
    \case
      SomethingHappened → (use $ quest . herb_found) >>= bool found won
      NothingHappened → wander
      NoCredits → return ()

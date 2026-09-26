# Brief: describing one range of a game's disassembly

A template for the agents the skill's "Describing a big range in parallel"
section sends out. Fill in the <placeholders> and the game-specific
paragraphs (what memory the game keeps outside the listing, which
tables to lay out how), save it in the scratchpad, and point each
agent at it with its own range and outputs. Knight Lore's eight agents
used this, 2026-09-26.

You are one of <N> agents, each describing one address range of <game>. Work only from the code;
do not run builds, do not touch any emulator, do not edit files in the
repository. Write only the two output files named in your task.

## The inputs (read-only)
- The listing: game-disassemblies/game_disassembly/<game>/<game>.skool
  (SkoolKit skool format; "@label=NAME" lines give names; lines starting "c$ADDR"/"b$ADDR"
  start an entry; " $ADDR" is an instruction or a data row; ";" lines are comments.)
  The generated .asm beside it (<game>.asm) has labels resolved in operands, which reads easier.
- The existing hand-written annotations: game-disassemblies/scripts/<game>_annotations.ctl
  Anything already there for your range must be carried into your fragment (improve it if the
  code shows it wrong or thin -- and say so in your notes), because the merge replaces
  that file's entries for your range with yours.
- The existing prose pages: game-disassemblies/scripts/<game>.ref
- <Memory the game keeps outside the listing -- variables, records -- and what is known of it.
  Ask the agent to work out what each address its code uses means.>

## Output 1: a control-file fragment  (<game>_part_<N>.ctl in the scratchpad)
SkoolKit control-file lines, for EVERY entry (routine or data block) that starts in your range:

    @ $ADDR label=new_name          only to replace a placeholder name (see naming)
    c $ADDR Title                   one line, sentence case, says what it does
    D $ADDR First paragraph of the description.
    . continuation lines start with ". "
    D $ADDR A second paragraph.
    R $ADDR HL what it holds on entry     (inputs; "O:A ..." style not needed -- write "R $ADDR A on exit, ...")
      $ADDR,N Comment on the instruction(s) at ADDR, N bytes
    E $ADDR Closing note, if there is something to say after the code.
    b $ADDR Title                   for a data block
    B $ADDR,N,M                     byte sub-blocks (N bytes, M per line) where a layout helps
    W $ADDR,N Comment               word sub-blocks: PUT THE COMMENT ON THE W LINE ITSELF. An
                                    indented comment line under a W turns the words back into bytes.

Rules that break the build if ignored:
- `  $ADDR,N`: ADDR must be the address of an instruction, and ADDR+N the address of the
  instruction after the last one covered (or the end of the entry). N is a byte count --
  count it from the listing's addresses, never by eye. Getting it wrong shifts the whole
  disassembly.
- Labels: lower_snake_case like the existing ones; NEVER end a label with _ and digits
  (skool2asm makes NAME_0, NAME_1 for jump targets); never reuse an existing label.
- A `#R$ADDR` in prose links to an entry: only use it for addresses that start an entry
  (a routine or data block), otherwise write the address plainly.
- Don't use SkoolKit macro names (#UDGARRAY etc.) in prose.
- No semicolons at the start of a continuation line.

Write the draft with instruction ranges -- `  $A-$B Comment` for the
instructions from $A to $B, `  $A Comment` for one -- and let the tool count
the bytes, then check the result:

    .venv-win/Scripts/python.exe game-disassemblies/scripts/ctl_tools.py ranges <skool> <draft> <fragment>
    .venv-win/Scripts/python.exe game-disassemblies/scripts/ctl_tools.py check <skool> <fragment> <START> <END>

It must end "OK".

## Naming
<Where the existing labels come from.> Keep the meaningful ones. Replace the placeholders --
loc_XXXX, sub_XXXX, byte_XXXX, off_XXXX, audio_XXXX, d_3467121516, continue_1 and the like --
with a real name for what the thing is or does. If a meaningful tcdev name is actually
wrong, you may rename it, but say why in the notes' "Renamed routines" table.
A borrowed disassembly's prose is NOT to be copied or paraphrased: describe from the code.

## What good looks like
Read the existing annotations for the style: prose sentences, say WHY where the obvious
reading would be wrong, name variables and records by what they mean, link routines with #R.
Every routine gets a title and at least one description paragraph; comment the
instructions that aren't self-evident (group a few instructions per comment where they do
one thing). Every data block gets a title and a description of its layout; tables of
addresses become W sub-blocks with a comment each; records one per line.
Be honest: if something is not understood, say "not yet worked out" rather than guess,
and put it under Open questions in the notes.

## Output 2: notes draft  (<game>_notes_<N>.md in the scratchpad)
Markdown, for the game's notes folder. One section per subject your range covers, each in
this shape (the skill's topic-file template):

    # <Subject>
    **Question this answers:** ...
    **Short answer:** two or three sentences.
    ## How it works        -- routines in call order (an ASCII call chain helps), record
                              layouts and tables (offset | field), variables by address and label
    ## How this was found  -- what you read and how you worked it out
    ## Confidence          -- confirmed by reading vs inferred; everything here is "read" unless
                              you say otherwise
    ## Renamed routines    -- | New name | Old name | Address | Role |
    ## Open questions

Then a final section "## Variables used" -- a table of every address below $6108 your code
reads or writes: | Address | Meaning | Evidence (which routine, how) |. These get merged
into the game's memory map, so be precise about what you are sure of.
Prose, addresses and names only: no byte dumps, no game text quoted beyond single words,
no pictures.

When done, reply with: the two file paths, the checker's final line, how many entries you
titled and labels you renamed, and the three most interesting things you found.

## Also
- Per-record lines that decode the game's level data (each room's contents, each
  piece's position) are not committed: describe the table's format in its
  entry, and say in the notes which table needs a build-time generator.
- If you find something wrong in another range (a wrong existing annotation, a table's
  real layout), say so in your reply: the parent passes it on.

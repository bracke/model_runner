--  The chat-template crossing: this engine's rendering set beside Python's
--  jinja2 reading the same template, conversation for conversation.
--
--  jinja2 is the implementation every chat template was written against,
--  so agreeing with it byte for byte is what "renders" means for one, and
--  the only way to know is to ask it. It is a Python library, so the asking
--  is a Python program; it lives here, as text, so that a checkout carries
--  the check and `tests cross` runs it rather than a script somebody once
--  had. The program hands each conversation to `tests render` and to
--  jinja2 and prints a line a case, with a diff where the two differ.
--
--  What is crossed:
--
--    a model's own template, read out of its file, against jinja2 reading
--    the same text: `tests cross --model PATH`;
--
--    a carried format against jinja2 reading the model's own template,
--    which is the check that matters for a format that stands in for one:
--    `tests cross --model PATH --format NAME`;
--
--    a template file against jinja2 reading it, with the model lending its
--    tokens: `tests cross --model PATH --template FILE`;
--
--    the expression suites -- the constructs the support matrix lists,
--    each written as a one-line template -- against jinja2:
--    `tests cross --model PATH --expressions`.
--
--  Fourteen conversations: plain, with a system turn, tools offered with
--  and without one, a call turn with text and one without, two calls
--  answered by two tool turns, a reply with no generation prompt,
--  reasoning kept in the exchange in progress and dropped from an earlier
--  one, a call whose arguments nest mappings and lists, a user turn
--  wrapped in a tool answer's markers, two system turns, a developer
--  turn, and a user turn whose content is a list of parts -- an image,
--  a text, a video.
--  `--think` and `--no-think` say what the caller says about reasoning;
--  `--without-tools` and `--without-reasoning` leave out the shapes a
--  carried format was never meant to match.
--
--  A machine without python3 or jinja2 skips rather than fails: the
--  crossing is evidence gathered where it can be, not a gate.
package Crossing is

   --  Run the crossing with the command line's own arguments.
   --
   --  @return The exit status: zero when every case agrees or the
   --    crossing was skipped for want of Python, one otherwise.
   function Run return Integer;

end Crossing;

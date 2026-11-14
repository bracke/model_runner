--  A message's own formatting: a little markup in the catalog's text.
--
--  A catalog entry is one line; within it
--
--    \n          breaks the line, and a line that begins "- " is a list's
--                item
--    **words**   is bold, *words* italic, `words` code (nothing inside
--                code is markup)
--    \\ \* \`    are the character itself
--
--  A marker opens only where text follows it and closes only where text
--  comes before it, on the same line, so the asterisks of a glob -- "a *
--  stands for", "specs/*/requirements.md" -- stay what they are.
--
--  Marked reads the markup into marks of its own: control characters a
--  catalog's text cannot hold, as Localization escapes every control in
--  it before reading. Render turns the marks into what a terminal shows
--  -- styles, and a bullet before each item, its lines wrapped under its
--  text -- or into plain text.
package Model_Runner.Markup is

   --  Read a message's markup into marks.
   --
   --  @param Template The message, its controls already escaped.
   --  @return The message, its markup made marks.
   function Marked (Template : String) return String;

   --  Whether a character is a mark.
   --
   --  @param C Character.
   --  @return True for a mark Marked puts in.
   function Is_Mark (C : Character) return Boolean;

   --  Whether text holds marks.
   --
   --  @param Item Text Marked made, or any.
   --  @return True when a mark is in it.
   function Has_Marks (Item : String) return Boolean;

   --  Text with marks as it is to be shown.
   --
   --  @param Item Text Marked made.
   --  @param Styled Whether styles are drawn -- bold, italic, code -- and an
   --    item's bullet is U+2022; otherwise plain text, an item's bullet a
   --    hyphen.
   --  @param Width The window's width: an item's lines wrapped to it, the
   --    lines after its first under its text. 0 leaves lines as they are.
   --  @return The text to show.
   function Render (Item : String; Styled : Boolean; Width : Natural := 0) return String;

   --  Text with marks as plain text: Render unstyled and unwrapped.
   --
   --  @param Item Text Marked made.
   --  @return The text without its marks.
   function Plain (Item : String) return String;

end Model_Runner.Markup;

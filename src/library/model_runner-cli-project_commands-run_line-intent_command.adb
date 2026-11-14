separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Intent_Command (Store : in out S.Store) is
   After    : Names.Vector;
   Flags    : Model_Runner.CLI.Intents.Quoted_Flags
     (1 .. Natural (All_Words.Length) + Ada.Strings.Fixed.Count (Line, ",") + 1) :=
     [others => False];
   --  Of the words, each NAME=VALUE whose value was quoted: it ends there.
   Closed   : Model_Runner.CLI.Intents.Quoted_Flags (Flags'Range) := [others => False];
   --  Whether a NAME=VALUE went before: the words after it are its text.
   Valued   : Boolean := False;
   Action   : constant String :=
     (if Natural (All_Words.Length) >= 2 then Ada.Characters.Handling.To_Lower (All_Words (2)) else "");
   --  Where only identifiers are named: a title's or a text's commas are
   --  their own -- /req new Parsing accepts REQ-1,REQ-2 inputs.
   Takes_Ids : constant Boolean :=
     Action in "show" | "accept" | "reject" | "reconsider" | "obsolete" | "block" | "unblock" | "verify"
             | "trace";
begin
   for Index in 2 .. Natural (All_Words.Length) loop
      --  REQ-001,REQ-002 -- or 1, 2 made REQ-001, and REQ-002 -- each its
      --  own, as a list is written; a value's commas stay its own.
      declare
         One        : constant String := All_Words (Index);
         Is_Id_List : Boolean := Takes_Ids and then not Valued and then Ada.Strings.Fixed.Index (One, ",") > 0
           and then Ada.Strings.Fixed.Index (One, "=") = 0
           and then not Began_Quoted_At (Quoted, Index);
         From       : Positive := One'First;
      begin
         if Is_Id_List then
            for At_Comma in One'First .. One'Last + 1 loop
               if At_Comma > One'Last or else One (At_Comma) = ',' then
                  declare
                     Piece : constant String := One (From .. At_Comma - 1);
                  begin
                     if Piece /= "" and then not Looks_Like_Id (Piece) then
                        Is_Id_List := False;
                     end if;
                  end;
                  From := At_Comma + 1;
               end if;
            end loop;
         end if;
         --  --verbose is how much is said, read before: not a word here.
         if One = "--verbose" and then Opt."=" (Command.Level, Opt.Verbose) then
            null;
         elsif Is_Id_List then
            From := One'First;
            for At_Comma in One'First .. One'Last + 1 loop
               if At_Comma > One'Last or else One (At_Comma) = ',' then
                  if At_Comma > From then
                     After.Append (One (From .. At_Comma - 1));
                  end if;
                  From := At_Comma + 1;
               end if;
            end loop;
         else
            Valued := Valued or else (Is_Setting (One) and then not Quoted_At (Quoted, All_Words, Index));
            After.Append (One);
            Flags (Natural (After.Length)) := Quoted_At (Quoted, All_Words, Index);
            Closed (Natural (After.Length)) :=
              Began_Quoted_At (Value_Flags, Index) or else Began_Quoted_At (Quoted, Index);
         end if;
      end;
   end loop;
   Model_Runner.CLI.Intents.Run
     (Store,
      (if Word = "/req" then Nt.Requirement
       elsif Word = "/decision" then Nt.Decision
       else Nt.Specification),
      After, Screen, Flags, Closed);
   --  One turned down by name: what still waits, as /reject says it.
   if Natural (All_Words.Length) >= 3 and then Ada.Characters.Handling.To_Lower (All_Words (2)) = "reject" then
      Say_Still_Waiting (Store);
   end if;
end Intent_Command;

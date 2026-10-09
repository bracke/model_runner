with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Hostkit;
with Hostkit.Process;

with Model_Runner.Platform;

package body Conformance.Parts is

   use Ada.Strings.Unbounded;

   -----------
   -- Count --
   -----------

   function Count return Positive is
     (Positive'Max (1, Positive'Min (8, Model_Runner.Platform.Core_Count - 1)));

   --  The fields a line carries, by name, in order.
   type Field is
     (Sequences, Compared, Worst_Abs, Worst_Rel, Lossy_Compared, Lossy_Worst_Abs, Lossy_Worst_Rel,
      Cached_Compared, Cached_Worst_Abs, Cached_Worst_Rel, Tiled_Compared, Tiled_Worst_Abs,
      Tiled_Worst_Rel, Integer_Compared, Integer_Worst_Abs, Integer_Worst_Rel, Eighth_Compared,
      Eighth_Worst_Abs, Eighth_Worst_Rel, Fourth_Compared, Fourth_Worst_Abs, Fourth_Worst_Rel,
      Mixed_Compared, Mixed_Worst_Abs, Mixed_Worst_Rel, Failures, Refused, Not_Applicable,
      Unlearned, Wanted, Requested, Formats, Architectures, Shapes, On_Device, Built, Decoded,
      Computed, Learned, Evaluated);

   --  A field's value, as a number.
   function Value_Of (Item : Report; Which : Field) return Long_Float is
     (case Which is
        when Sequences => Long_Float (Item.Sequences),
        when Compared => Long_Float (Item.Compared),
        when Worst_Abs => Item.Worst_Abs,
        when Worst_Rel => Item.Worst_Rel,
        when Lossy_Compared => Long_Float (Item.Lossy_Compared),
        when Lossy_Worst_Abs => Item.Lossy_Worst_Abs,
        when Lossy_Worst_Rel => Item.Lossy_Worst_Rel,
        when Cached_Compared => Long_Float (Item.Cached_Compared),
        when Cached_Worst_Abs => Item.Cached_Worst_Abs,
        when Cached_Worst_Rel => Item.Cached_Worst_Rel,
        when Tiled_Compared => Long_Float (Item.Tiled_Compared),
        when Tiled_Worst_Abs => Item.Tiled_Worst_Abs,
        when Tiled_Worst_Rel => Item.Tiled_Worst_Rel,
        when Integer_Compared => Long_Float (Item.Integer_Compared),
        when Integer_Worst_Abs => Item.Integer_Worst_Abs,
        when Integer_Worst_Rel => Item.Integer_Worst_Rel,
        when Eighth_Compared => Long_Float (Item.Eighth_Compared),
        when Eighth_Worst_Abs => Item.Eighth_Worst_Abs,
        when Eighth_Worst_Rel => Item.Eighth_Worst_Rel,
        when Fourth_Compared => Long_Float (Item.Fourth_Compared),
        when Fourth_Worst_Abs => Item.Fourth_Worst_Abs,
        when Fourth_Worst_Rel => Item.Fourth_Worst_Rel,
        when Mixed_Compared => Long_Float (Item.Mixed_Compared),
        when Mixed_Worst_Abs => Item.Mixed_Worst_Abs,
        when Mixed_Worst_Rel => Item.Mixed_Worst_Rel,
        when Failures => Long_Float (Item.Failures),
        when Refused => Long_Float (Item.Refused),
        when Not_Applicable => Long_Float (Item.Not_Applicable),
        when Unlearned => Long_Float (Item.Unlearned),
        when Wanted => Long_Float (Item.Wanted),
        when Requested => Long_Float (Item.Requested),
        when Formats => Long_Float (Item.Formats),
        when Architectures => Long_Float (Item.Architectures),
        when Shapes => Long_Float (Item.Shapes),
        when On_Device => Long_Float (Item.On_Device),
        when Built => Long_Float (Item.Built),
        when Decoded => Long_Float (Item.Decoded),
        when Computed => Long_Float (Item.Computed),
        when Learned => Long_Float (Item.Learned),
        when Evaluated => Long_Float (Item.Evaluated));

   procedure Set (Item : in out Report; Which : Field; Value : Long_Float) is
      Whole : constant Natural := Natural (Long_Float'Max (0.0, Value));
   begin
      case Which is
         when Sequences => Item.Sequences := Whole;
         when Compared => Item.Compared := Whole;
         when Worst_Abs => Item.Worst_Abs := Value;
         when Worst_Rel => Item.Worst_Rel := Value;
         when Lossy_Compared => Item.Lossy_Compared := Whole;
         when Lossy_Worst_Abs => Item.Lossy_Worst_Abs := Value;
         when Lossy_Worst_Rel => Item.Lossy_Worst_Rel := Value;
         when Cached_Compared => Item.Cached_Compared := Whole;
         when Cached_Worst_Abs => Item.Cached_Worst_Abs := Value;
         when Cached_Worst_Rel => Item.Cached_Worst_Rel := Value;
         when Tiled_Compared => Item.Tiled_Compared := Whole;
         when Tiled_Worst_Abs => Item.Tiled_Worst_Abs := Value;
         when Tiled_Worst_Rel => Item.Tiled_Worst_Rel := Value;
         when Integer_Compared => Item.Integer_Compared := Whole;
         when Integer_Worst_Abs => Item.Integer_Worst_Abs := Value;
         when Integer_Worst_Rel => Item.Integer_Worst_Rel := Value;
         when Eighth_Compared => Item.Eighth_Compared := Whole;
         when Eighth_Worst_Abs => Item.Eighth_Worst_Abs := Value;
         when Eighth_Worst_Rel => Item.Eighth_Worst_Rel := Value;
         when Fourth_Compared => Item.Fourth_Compared := Whole;
         when Fourth_Worst_Abs => Item.Fourth_Worst_Abs := Value;
         when Fourth_Worst_Rel => Item.Fourth_Worst_Rel := Value;
         when Mixed_Compared => Item.Mixed_Compared := Whole;
         when Mixed_Worst_Abs => Item.Mixed_Worst_Abs := Value;
         when Mixed_Worst_Rel => Item.Mixed_Worst_Rel := Value;
         when Failures => Item.Failures := Whole;
         when Refused => Item.Refused := Whole;
         when Not_Applicable => Item.Not_Applicable := Whole;
         when Unlearned => Item.Unlearned := Whole;
         when Wanted => Item.Wanted := Whole;
         when Requested => Item.Requested := Whole;
         when Formats => Item.Formats := Whole;
         when Architectures => Item.Architectures := Whole;
         when Shapes => Item.Shapes := Whole;
         when On_Device => Item.On_Device := Whole;
         when Built => Item.Built := Duration (Value);
         when Decoded => Item.Decoded := Duration (Value);
         when Computed => Item.Computed := Duration (Value);
         when Learned => Item.Learned := Duration (Value);
         when Evaluated => Item.Evaluated := Duration (Value);
      end case;
   end Set;

   --  The fields that are a worst of the parts, not a sum; and those every
   --  part has the same of.
   function Is_Worst (Which : Field) return Boolean is
     (Field'Image (Which)'Length > 5
      and then (Ada.Strings.Fixed.Index (Field'Image (Which), "WORST") > 0));

   function Is_Same (Which : Field) return Boolean is (Which in Formats | Shapes);

   -------------
   -- Line_Of --
   -------------

   function Line_Of (Item : Report) return String is
      Said : Unbounded_String := To_Unbounded_String ("conformance-part:");
   begin
      for Which in Field loop
         Append (Said, " " & Field'Image (Which) & "=" & Long_Float'Image (Value_Of (Item, Which)));
      end loop;
      return To_String (Said);
   end Line_Of;

   ---------------
   -- Read_Line --
   ---------------

   procedure Read_Line (Line : String; Item : out Report; Read : out Boolean) is
   begin
      Item := (others => <>);
      Read := Ada.Strings.Fixed.Index (Line, "conformance-part:") = Line'First;
      if not Read then
         return;
      end if;
      for Which in Field loop
         declare
            Key   : constant String := " " & Field'Image (Which) & "=";
            At_It : constant Natural := Ada.Strings.Fixed.Index (Line, Key);
            Stop  : Natural;
         begin
            if At_It = 0 then
               Read := False;
               return;
            end if;
            Stop := At_It + Key'Length;
            --  The value runs to the next field's space, past its own
            --  leading one.
            while Stop <= Line'Last and then Line (Stop) = ' ' loop
               Stop := Stop + 1;
            end loop;
            while Stop <= Line'Last and then Line (Stop) /= ' ' loop
               Stop := Stop + 1;
            end loop;
            Set (Item, Which, Long_Float'Value (Line (At_It + Key'Length .. Stop - 1)));
         end;
      end loop;
   exception
      when others =>
         Read := False;
   end Read_Line;

   ---------
   -- Add --
   ---------

   procedure Add (Into : in out Report; Part : Report) is
   begin
      for Which in Field loop
         Set (Into, Which,
              (if Is_Worst (Which) or else Is_Same (Which)
               then Long_Float'Max (Value_Of (Into, Which), Value_Of (Part, Which))
               else Value_Of (Into, Which) + Value_Of (Part, Which)));
      end loop;
      Into.Ran := Accounted (Into);
   end Add;

   ---------
   -- Run --
   ---------

   procedure Run
     (Result      : out Report;
      Short_Sweep : Boolean;
      Program     : String;
      Integers    : Boolean)
   is
      Parts : constant Positive := Count;

      type Outcome is record
         Line   : Unbounded_String;
         Errors : Unbounded_String;
         Ran    : Boolean := False;
      end record;
      Outcomes : array (1 .. Parts) of Outcome;

      function Image (Value : Positive) return String is
         Raw : constant String := Positive'Image (Value);
      begin
         return Raw (Raw'First + 1 .. Raw'Last);
      end Image;

      procedure Run_Part (Part : Positive) is
         Words  : Hostkit.String_Vectors.Vector;
         Out_At : constant String := "obj/conformance-part-" & Image (Part) & ".out";
         Err_At : constant String := "obj/conformance-part-" & Image (Part) & ".err";
         Happened : Hostkit.Process.Process_Outcome;

         function Read (Path : String) return Unbounded_String is
            File : Ada.Text_IO.File_Type;
            Said : Unbounded_String;
         begin
            if not Ada.Directories.Exists (Path) then
               return Said;
            end if;
            Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
            while not Ada.Text_IO.End_Of_File (File) loop
               Append (Said, Ada.Text_IO.Get_Line (File) & ASCII.LF);
            end loop;
            Ada.Text_IO.Close (File);
            return Said;
         end Read;
      begin
         Words.Append (To_Unbounded_String ("conformance"));
         Words.Append (To_Unbounded_String ("--part"));
         Words.Append (To_Unbounded_String (Image (Part) & "/" & Image (Parts)));
         if Short_Sweep then
            Words.Append (To_Unbounded_String ("--short"));
         end if;
         if Integers then
            Words.Append (To_Unbounded_String ("--arith"));
            Words.Append (To_Unbounded_String ("int8"));
         end if;
         Happened := Hostkit.Process.Run_Captured
           (Program, Words, Stdout_Path => Out_At, Stderr_Path => Err_At);
         Outcomes (Part).Ran := Happened.Started;
         Outcomes (Part).Line := Read (Out_At);
         Outcomes (Part).Errors := Read (Err_At);
      end Run_Part;
   begin
      Result := (others => <>);
      declare
         protected Dispatch is
            procedure Next (Part : out Natural);
         private
            Given : Natural := 0;
         end Dispatch;

         protected body Dispatch is
            procedure Next (Part : out Natural) is
            begin
               if Given < Parts then
                  Given := Given + 1;
                  Part := Given;
               else
                  Part := 0;
               end if;
            end Next;
         end Dispatch;

         task type Runner;
         task body Runner is
            Part : Natural;
         begin
            loop
               Dispatch.Next (Part);
               exit when Part = 0;
               Run_Part (Part);
            end loop;
         end Runner;

         Crew : array (1 .. Parts) of Runner;
         pragma Unreferenced (Crew);
      begin
         null;  --  the block's end waits for every part
      end;

      --  Every part's report added up, and what each said on its standard
      --  error passed on: the first disagreement is said there.
      for Part in Outcomes'Range loop
         declare
            Text  : constant String := To_String (Outcomes (Part).Line);
            Start : Positive := Text'First;
            Found : Boolean := False;
         begin
            for Index in Text'Range loop
               if Text (Index) = ASCII.LF then
                  declare
                     Item : Report;
                     Read : Boolean;
                  begin
                     Read_Line (Text (Start .. Index - 1), Item, Read);
                     if Read then
                        Add (Result, Item);
                        Found := True;
                     end if;
                  end;
                  Start := Index + 1;
               end if;
            end loop;
            if Length (Outcomes (Part).Errors) > 0 then
               Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, To_String (Outcomes (Part).Errors));
            end if;
            --  A part with no report: the whole is not accounted for.
            if not Found then
               Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error,
                                     "conformance: part" & Positive'Image (Part) & " of"
                                     & Positive'Image (Parts) & " printed no report");
               Result.Wanted := Result.Wanted + 1;
            end if;
         end;
      end loop;
      Result.Ran := Accounted (Result);
   end Run;

end Conformance.Parts;

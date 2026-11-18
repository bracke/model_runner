with Ada.Characters.Latin_1;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Hostkit.Fs;

with Model_Runner;
with Model_Runner.Expert_Cache_Recommendations;
with Model_Runner.Text;

with Expert_Cache_Bench;

package body Expert_Cache_Matrix is

   package IO renames Ada.Text_IO;
   package US renames Ada.Strings.Unbounded;

   Max_Models : constant := 32;
   type Model_Row is record
      Path   : US.Unbounded_String;
      Memory : Interfaces.Unsigned_64 := 0;
   end record;
   type Model_Rows is array (Positive range 1 .. Max_Models) of Model_Row;

   function Trim (Item : String) return String is
     (Ada.Strings.Fixed.Trim (Item, Ada.Strings.Both));

   function Suffix (Index : Positive) return String is
      Raw : constant String := Positive'Image (Index);
   begin
      return Raw (Raw'First + 1 .. Raw'Last);
   end Suffix;

   procedure Run
     (Manifest        : String;
      Prompt          : String;
      Turns           : String;
      Cache_Sizes     : String;
      Report_Path     : String;
      Recommendation_Path : String;
      Tokens          : Positive;
      Threads         : Positive;
      Context         : Natural;
      Repeats         : Positive;
      Default_Device_Memory : Interfaces.Unsigned_64;
      Minimum_Gain    : Long_Float;
      Logit_Tolerance : Model_Runner.Numerics.Real;
      Leg_Drift_Limit : Long_Float;
      Success         : out Boolean)
   is
      Rows  : Model_Rows;
      Count : Natural := 0;
      File  : IO.File_Type;
      Out_File : IO.File_Type;
      Part  : constant String := Report_Path & ".part";

      procedure Read_Manifest is
      begin
         IO.Open (File, IO.In_File, Manifest);
         while not IO.End_Of_File (File) loop
            declare
               Line : constant String := Trim (IO.Get_Line (File));
               Tab  : constant Natural :=
                 Ada.Strings.Fixed.Index
                   (Line, String'(1 => Ada.Characters.Latin_1.HT));
               Path : constant String :=
                 (if Tab = 0 then Line else Trim (Line (Line'First .. Tab - 1)));
               Memory_Text : constant String :=
                 (if Tab = 0 then "" else Trim (Line (Tab + 1 .. Line'Last)));
            begin
               if Line = "" or else Line (Line'First) = '#' then
                  null;
               elsif Count = Max_Models or else Path = ""
                 or else not Ada.Directories.Exists (Path)
               then
                  raise Constraint_Error;
               else
                  Count := Count + 1;
                  Rows (Count).Path := US.To_Unbounded_String (Path);
                  Rows (Count).Memory :=
                    (if Memory_Text = "" then Default_Device_Memory
                     else Interfaces.Unsigned_64'Value (Memory_Text));
               end if;
            end;
         end loop;
         IO.Close (File);
         if Count = 0 then
            raise Constraint_Error;
         end if;
      end Read_Manifest;

      procedure Copy_JSON (Path : String) is
         Input : IO.File_Type;
      begin
         IO.Open (Input, IO.In_File, Path);
         while not IO.End_Of_File (Input) loop
            IO.Put_Line (Out_File, IO.Get_Line (Input));
         end loop;
         IO.Close (Input);
      exception
         when others =>
            if IO.Is_Open (Input) then
               IO.Close (Input);
            end if;
            raise;
      end Copy_JSON;
   begin
      Success := False;
      if Manifest = "" or else Report_Path = ""
        or else not Ada.Directories.Exists (Manifest)
      then
         return;
      end if;
      Read_Manifest;

      declare
         Parent : constant String := Ada.Directories.Containing_Directory (Report_Path);
      begin
         if Parent /= "" and then not Ada.Directories.Exists (Parent) then
            Ada.Directories.Create_Path (Parent);
         end if;
      end;
      IO.Create (Out_File, IO.Out_File, Part);
      IO.Put_Line (Out_File, "{");
      IO.Put_Line (Out_File, "  ""schema"":""expert-cache-matrix/2"",");
      IO.Put_Line
        (Out_File, "  ""runtime"":"
         & Model_Runner.Text.JSON_Quoted (Model_Runner.Version) & ",");
      IO.Put_Line
        (Out_File, "  ""engine_id"":"
         & Model_Runner.Text.JSON_Quoted
             (Model_Runner.Expert_Cache_Recommendations.Engine_Identity)
         & ",");
      IO.Put_Line (Out_File, "  ""models"":[");

      for Index in 1 .. Count loop
         declare
            Temp : constant String :=
              Report_Path & ".model-" & Suffix (Index) & ".json";
            Completed : Boolean;
         begin
            Expert_Cache_Bench.Run
              (Model => US.To_String (Rows (Index).Path),
               Prompt => Prompt,
               Turns => Turns,
               Cache_Sizes => Cache_Sizes,
               Report_Path => Temp,
               Recommendation_Path => Recommendation_Path,
               Tokens => Tokens,
               Threads => Threads,
               Context => Context,
               Repeats => Repeats,
               Device_Memory => Rows (Index).Memory,
               Minimum_Gain => Minimum_Gain,
               Logit_Tolerance => Logit_Tolerance,
               Leg_Drift_Limit => Leg_Drift_Limit,
               Success => Completed);
            if not Completed then
               raise Constraint_Error;
            end if;
            Copy_JSON (Temp);
            Ada.Directories.Delete_File (Temp);
            IO.Put_Line
              (Out_File, (if Index = Count then "" else ","));
         end;
      end loop;
      IO.Put_Line (Out_File, "  ]");
      IO.Put_Line (Out_File, "}");
      IO.Close (Out_File);
      Success := Hostkit.Fs.Replace_File (Part, Report_Path);
   exception
      when others =>
         if IO.Is_Open (File) then
            IO.Close (File);
         end if;
         if IO.Is_Open (Out_File) then
            IO.Close (Out_File);
         end if;
         Success := False;
   end Run;

end Expert_Cache_Matrix;

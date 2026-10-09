with Ada.Calendar;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Hostkit;
with Hostkit.Descriptors;
with Hostkit.Fs;
with Hostkit.Process;
with Hostkit.Pty;
with Hostkit.Spawn;

package body Agent_Trial is

   use Ada.Strings.Unbounded;
   use type Ada.Streams.Stream_Element_Offset;

   LF : constant Character := ASCII.LF;

   --  How the session shows a call: an arrow, in UTF-8, and a space.
   Arrow : constant String :=
     Character'Val (16#E2#) & Character'Val (16#86#) & Character'Val (16#92#) & " ";

   --  A task: its name, its kind, and what it asks.
   type Trial_Task is record
      Name  : Unbounded_String;
      Kind  : Unbounded_String;
      Notes : Unbounded_String;
   end record;

   function T (Name, Kind, Notes : String) return Trial_Task is
     ((To_Unbounded_String (Name), To_Unbounded_String (Kind), To_Unbounded_String (Notes)));

   --  The tasks: one that changes part of a file, and one that only finds
   --  -- the two things a coding agent most does.
   Tasks : constant array (1 .. 2) of Trial_Task :=
     [T ("edit", "implementation",
         "In src/calc.adb make Add return Integer'Last when A + B would overflow above it and"
         & " Integer'First when it would overflow below, instead of raising. Change only Add."),
      T ("find", "analysis",
         "Find which units use the package Calc, and in which file and on which line Times is"
         & " declared. Report them. Change no file.")];

   --  The project a task is run in, made fresh: a package, its body, and a
   --  main that uses it, under version control.
   procedure Make_Project (Root : String) is
      procedure Put (Name, Text : String) is
         File : Ada.Text_IO.File_Type;
      begin
         Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Root & "/" & Name);
         Ada.Text_IO.Put (File, Text);
         Ada.Text_IO.Close (File);
      end Put;

      procedure Git (Words : String) is
         Line    : Hostkit.String_Vectors.Vector;
         Start   : Positive := Words'First;
         Ignored : Hostkit.Process.Process_Outcome;
      begin
         Line.Append (To_Unbounded_String ("-C"));
         Line.Append (To_Unbounded_String (Root));
         Line.Append (To_Unbounded_String ("-c"));
         Line.Append (To_Unbounded_String ("user.email=trial@example.invalid"));
         Line.Append (To_Unbounded_String ("-c"));
         Line.Append (To_Unbounded_String ("user.name=trial"));
         for Index in Words'First .. Words'Last + 1 loop
            if Index > Words'Last or else Words (Index) = ' ' then
               Line.Append (To_Unbounded_String (Words (Start .. Index - 1)));
               Start := Index + 1;
            end if;
         end loop;
         Ignored := Hostkit.Process.Run_Captured
           ("git", Line, Stdout_Path => Hostkit.Fs.Null_Device, Stderr_Path => Hostkit.Fs.Null_Device);
      end Git;
   begin
      if Ada.Directories.Exists (Root) then
         Ada.Directories.Delete_Tree (Root);
      end if;
      Ada.Directories.Create_Path (Root & "/src");
      Put ("src/calc.ads",
           "package Calc is" & LF & "   --  The sum of A and B." & LF
           & "   function Add (A, B : Integer) return Integer;" & LF & "   --  A times B." & LF
           & "   function Times (A, B : Integer) return Integer;" & LF & "end Calc;" & LF);
      Put ("src/calc.adb",
           "package body Calc is" & LF & LF
           & "   function Add (A, B : Integer) return Integer is" & LF & "   begin" & LF
           & "      return A + B;" & LF & "   end Add;" & LF & LF
           & "   function Times (A, B : Integer) return Integer is" & LF
           & "      Result : Integer := 0;" & LF & "   begin" & LF
           & "      for I in 1 .. B loop" & LF & "         Result := Add (Result, A);" & LF
           & "      end loop;" & LF & "      return Result;" & LF & "   end Times;" & LF & LF
           & "end Calc;" & LF);
      Put ("src/main.adb",
           "with Ada.Text_IO;" & LF & "with Calc;" & LF & "procedure Main is" & LF & "begin" & LF
           & "   Ada.Text_IO.Put_Line (Integer'Image (Calc.Times (6, 7)));" & LF & "end Main;" & LF);
      Git ("init -q");
      Git ("add -A");
      Git ("commit -qm start");
   end Make_Project;

   --  Text without the terminal's escape sequences and carriage returns.
   function Plain (Text : String) return String is
      Result : String (1 .. Text'Length);
      Last   : Natural := 0;
      Index  : Positive := Text'First;
   begin
      while Index <= Text'Last loop
         if Text (Index) = ASCII.ESC and then Index < Text'Last and then Text (Index + 1) = '[' then
            Index := Index + 2;
            while Index <= Text'Last and then Text (Index) not in 'A' .. 'Z' | 'a' .. 'z' loop
               Index := Index + 1;
            end loop;
            Index := Index + 1;
         elsif Text (Index) = ASCII.CR then
            Index := Index + 1;
         else
            Last := Last + 1;
            Result (Last) := Text (Index);
            Index := Index + 1;
         end if;
      end loop;
      return Result (1 .. Last);
   end Plain;

   ---------
   -- Run --
   ---------

   procedure Run
     (Model   : String;
      Program : String;
      Options : String;
      Only    : String;
      Clean   : out Boolean)
   is
   begin
      Clean := True;
      for One of Tasks loop
         if Only = "" or else Only = To_String (One.Name) then
            declare
               Name    : constant String := To_String (One.Name);
               Root    : constant String := Ada.Directories.Full_Name ("obj/agent-trial-" & Name);
               Project : constant String := Ada.Directories.Simple_Name (Root);
               Pair    : Hostkit.Pty.Pair;
               Spawned : Hostkit.Spawn.Options;
               Child   : Hostkit.Spawn.Process_Handle;
               Ended   : Hostkit.Spawn.Status;
               Seen    : Unbounded_String;
               Began   : constant Ada.Calendar.Time := Ada.Calendar.Clock;
               Buffer  : Ada.Streams.Stream_Element_Array (1 .. 4096);
               Last    : Ada.Streams.Stream_Element_Offset;

               procedure Keep_Variable (Variable, Value : String) is
               begin
                  if Variable /= "TERM" then
                     Spawned.Environment.Append (To_Unbounded_String (String'(Variable & "=" & Value)));
                  end if;
               end Keep_Variable;

               --  Read what arrives until Text has, after From, or the
               --  seconds are up.
               function Wait_For (Text : String; Seconds : Duration) return Boolean is
                  use type Ada.Calendar.Time;
                  From  : constant Natural := Length (Seen);
                  Until_At : constant Ada.Calendar.Time := Ada.Calendar.Clock + Seconds;
               begin
                  loop
                     if Ada.Strings.Fixed.Index (Plain (Slice (Seen, From + 1, Length (Seen))), Text) > 0 then
                        return True;
                     end if;
                     exit when Ada.Calendar.Clock > Until_At;
                     if Hostkit.Descriptors.Wait_Readable (Pair.From_Child, 500) then
                        exit when Hostkit.Descriptors."/="
                                    (Hostkit.Descriptors.Read (Pair.From_Child, Buffer, Last),
                                     Hostkit.Descriptors.Transfer_Ok)
                          or else Last < Buffer'First;
                        for Byte of Buffer (Buffer'First .. Last) loop
                           Append (Seen, Character'Val (Byte));
                        end loop;
                     end if;
                  end loop;
                  return False;
               end Wait_For;

               procedure Send (Line : String) is
                  Bytes : Ada.Streams.Stream_Element_Array
                    (1 .. Ada.Streams.Stream_Element_Offset (Line'Length + 1));
                  Wrote : Ada.Streams.Stream_Element_Offset;
                  pragma Warnings (Off, Wrote);
                  Ignored : Hostkit.Descriptors.Transfer_Outcome;
               begin
                  for Index in Line'Range loop
                     Bytes (Ada.Streams.Stream_Element_Offset (Index - Line'First + 1)) :=
                       Character'Pos (Line (Index));
                  end loop;
                  Bytes (Bytes'Last) := 13;
                  Ignored := Hostkit.Descriptors.Write (Pair.To_Child, Bytes, Wrote);
               end Send;

               Words  : Hostkit.String_Vectors.Vector;
               Worked : Boolean := False;
            begin
               Make_Project (Root);
               if not Hostkit.Pty.Is_Supported or else not Hostkit.Pty.Open (Pair) then
                  Ada.Text_IO.Put_Line ("agent-trial: no terminal to run a session on");
                  Clean := False;
                  return;
               end if;
               Ada.Environment_Variables.Iterate (Keep_Variable'Access);
               Spawned.Environment.Append (To_Unbounded_String ("TERM=xterm"));
               Spawned.Replace_Environment := True;
               Spawned.Working_Directory := To_Unbounded_String (Root);
               if not (Hostkit.Pty.Set_Size (Pair, (Rows => 50, Columns => 200))
                       and then Hostkit.Pty.Attach (Pair, Spawned))
               then
                  Clean := False;
                  return;
               end if;
               Words.Append (To_Unbounded_String (Model));
               Words.Append (To_Unbounded_String ("--context-size"));
               Words.Append (To_Unbounded_String ("8192"));
               declare
                  Start : Positive := Options'First;
               begin
                  for Index in Options'First .. Options'Last + 1 loop
                     if Index > Options'Last or else Options (Index) = ' ' then
                        if Index > Start then
                           Words.Append (To_Unbounded_String (Options (Start .. Index - 1)));
                        end if;
                        Start := Index + 1;
                     end if;
                  end loop;
               end;
               if Hostkit.Spawn."/=" (Hostkit.Spawn.Start (Program, Words, Spawned, Child),
                                      Hostkit.Spawn.Spawn_Ok)
               then
                  Ada.Text_IO.Put_Line ("agent-trial: " & Program & " did not start");
                  Clean := False;
                  return;
               end if;
               Hostkit.Pty.Close_Device (Pair);

               --  The session, as a person would drive it.
               if Wait_For ("Interactive mode", 300.0) then
                  Send ("/init");
                  if Wait_For ("Select project type", 30.0) then
                     Send ("");
                     if Wait_For ("as planned", 30.0) then
                        Send ("");
                        if Wait_For ("initialized", 30.0) then
                           Send ("/task new Trial " & Name & " kind=" & To_String (One.Kind)
                                 & (if To_String (One.Kind) = "implementation"
                                    then " component=" & Project else "")
                                 & " notes=" & To_String (One.Notes));
                           if Wait_For ("created TASK-", 30.0) then
                              Send ("/accept TASK-001");
                              if Wait_For ("ready", 30.0) then
                                 Send ("/work TASK-001");
                                 Worked := Wait_For ("How it came out", 1800.0);
                                 declare
                                    Ignored : constant Boolean := Wait_For ("> ", 20.0);
                                 begin
                                    null;
                                 end;
                              end if;
                           end if;
                        end if;
                     end if;
                  end if;
               end if;
               Send ("/exit");
               declare
                  Ignored : constant Boolean := Wait_For ("never said", 5.0);
               begin
                  null;
               end;
               Hostkit.Pty.Close (Pair);
               declare
                  Ignored : constant Boolean := Hostkit.Spawn.Wait (Child, Hostkit.Spawn.Wait_Block, Ended);
               begin
                  null;
               end;

               --  What came of it.
               declare
                  use type Ada.Calendar.Time;
                  Text    : constant String := Plain (To_String (Seen));
                  Took    : constant Duration := Ada.Calendar.Clock - Began;
                  Calls   : Natural := 0;
                  Used    : Unbounded_String;
                  Outcome : Unbounded_String := To_Unbounded_String ("did not end");
                  Figures : Unbounded_String;
                  Start   : Positive := Text'First;
               begin
                  for Index in Text'Range loop
                     if Text (Index) = LF then
                        declare
                           Line : constant String :=
                             Ada.Strings.Fixed.Trim (Text (Start .. Index - 1), Ada.Strings.Both);
                        begin
                           --  A call, as the session shows one: an arrow, the tool.
                           if Line'Length > Arrow'Length
                             and then Line (Line'First .. Line'First + Arrow'Length - 1) = Arrow
                           then
                              Calls := Calls + 1;
                              declare
                                 Rest  : constant String := Line (Line'First + Arrow'Length .. Line'Last);
                                 Space : constant Natural := Ada.Strings.Fixed.Index (Rest, " ");
                                 Tool  : constant String :=
                                   (if Space = 0 then Rest else Rest (Rest'First .. Space - 1));
                              begin
                                 if Ada.Strings.Fixed.Index (To_String (Used), Tool) = 0 then
                                    Append (Used, (if Length (Used) = 0 then "" else ", ") & Tool);
                                 end if;
                              end;
                           elsif Ada.Strings.Fixed.Index (Line, "the task is ") = 1
                             or else Ada.Strings.Fixed.Index (Line, "the task failed") = 1
                           then
                              Outcome := To_Unbounded_String
                                (Line (Line'First .. Natural'Min (Line'Last, Line'First + 80)));
                           elsif Ada.Strings.Fixed.Index (Line, "calls before the first change") = 1 then
                              Figures := To_Unbounded_String (Line);
                           end if;
                        end;
                        Start := Index + 1;
                     end if;
                  end loop;
                  if not Worked or else Ada.Strings.Fixed.Index (To_String (Outcome), "complete") = 0 then
                     Clean := False;
                  end if;

                  --  What it changed, as version control sees it.
                  declare
                     Line  : Hostkit.String_Vectors.Vector;
                     Diff  : constant String := Root & "/.trial-diff";
                     Ran   : Hostkit.Process.Process_Outcome;
                     Said  : Unbounded_String;
                     File  : Ada.Text_IO.File_Type;
                  begin
                     for Word of Hostkit.String_Vectors.Vector'
                       ([To_Unbounded_String ("-C"), To_Unbounded_String (Root), To_Unbounded_String ("diff"),
                         To_Unbounded_String ("--shortstat"), To_Unbounded_String ("--"),
                         To_Unbounded_String ("src")])
                     loop
                        Line.Append (Word);
                     end loop;
                     Ran := Hostkit.Process.Run_Captured ("git", Line, Stdout_Path => Diff);
                     if Ran.Started and then Ada.Directories.Exists (Diff) then
                        Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Diff);
                        while not Ada.Text_IO.End_Of_File (File) loop
                           Append (Said, Ada.Strings.Fixed.Trim (Ada.Text_IO.Get_Line (File), Ada.Strings.Both));
                        end loop;
                        Ada.Text_IO.Close (File);
                     end if;
                     Ada.Text_IO.Put_Line
                       ("agent-trial " & Name & ": " & To_String (Outcome)
                        & LF & "  time:" & Integer'Image (Integer (Took)) & " s; calls:" & Natural'Image (Calls)
                        & (if Length (Used) = 0 then "" else " (" & To_String (Used) & ")")
                        & LF & "  " & (if Length (Figures) = 0 then "(no work figures)" else To_String (Figures))
                        & LF & "  changed: " & (if Length (Said) = 0 then "nothing" else To_String (Said))
                        & LF & "  session kept in " & Root);
                  end;
               end;
               --  The session as it went, for a reader who wants all of it.
               declare
                  File : Ada.Text_IO.File_Type;
               begin
                  Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Root & "/.trial-session.txt");
                  Ada.Text_IO.Put (File, Plain (To_String (Seen)));
                  Ada.Text_IO.Close (File);
               end;
            end;
         end if;
      end loop;
   end Run;

end Agent_Trial;

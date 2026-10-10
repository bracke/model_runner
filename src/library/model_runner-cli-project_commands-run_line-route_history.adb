separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Route_History is

   package Ev renames Model_Runner.Framework.Events;

   --  The most a listing shows: the latest, the earlier being in the log.
   Shown_At_Most : constant := 20;

   procedure Answer (Store : in out S.Store) is
      Given : constant String := Ada.Characters.Handling.To_Upper (Argument (1));
      Asked : constant String :=
        (if Given /= "" and then Given'Length <= 6 and then (for all C of Given => C in '0' .. '9')
         then "TASK-" & [1 .. Integer'Max (0, 3 - Given'Length) => '0'] & Given
         else Given);
      --  Nothing named: the latest alone are read, not the log whole.
      Log   : constant Ev.Event_List :=
        (if Asked = "" then Ev.Latest (Store, Shown_At_Most) else Ev.Since (Store, 0));

      --  Whether Text names Asked as a whole identifier, not the front of
      --  a longer one.
      function Names (Text : String) return Boolean is
         At_Name : Natural := Ada.Strings.Fixed.Index (Text, Asked);
      begin
         while At_Name > 0 loop
            if At_Name + Asked'Length > Text'Last
              or else Text (At_Name + Asked'Length) not in '0' .. '9'
            then
               return True;
            end if;
            At_Name := Ada.Strings.Fixed.Index (Text, Asked, At_Name + 1);
         end loop;
         return False;
      end Names;

      function About (Index : Positive) return Boolean is
         Event : constant Ev.Event := Ev.Element (Log, Index);
      begin
         return Asked = ""
           or else To_String (Event.Subject) = Asked
           or else Names (To_String (Event.Detail));
      end About;

      Matching : Natural := 0;
      Skipped  : Natural := 0;
   begin
      for Index in 1 .. Ev.Length (Log) loop
         if About (Index) then
            Matching := Matching + 1;
         end if;
      end loop;
      if Matching = 0 then
         Pres.Put_Note (Screen, "cli.history.none", [Loc.Named ("name", Asked)]);
         return;
      end if;
      declare
         Total : constant Natural := (if Asked = "" then Ev.Count (Store) else Matching);
      begin
         if Total > Shown_At_Most then
            Pres.Put_Note (Screen, "cli.history.earlier",
                           [Loc.Named ("count", Image (Total - Shown_At_Most)),
                            Loc.Named ("total", Image (Total))]);
         end if;
      end;
      for Index in 1 .. Ev.Length (Log) loop
         if About (Index) then
            if Skipped < Matching - Shown_At_Most then
               Skipped := Skipped + 1;
            else
               declare
                  Event : constant Ev.Event := Ev.Element (Log, Index);
               begin
                  Pres.Put_Note (Screen, "cli.history.event",
                                 [Loc.Named ("index", Image (Event.Sequence)),
                                  Loc.Named ("other", To_String (Event.Occurred_At)),
                                  Loc.Named ("value", To_String (Event.Kind_Word)),
                                  Loc.Named ("name", To_String (Event.Subject)),
                                  Loc.Named ("detail", To_String (Event.Detail))]);
                  --  Written by a later build, and waiting for one: said
                  --  where it is listed, not left to look like any other.
                  if not Event.Known then
                     Pres.Put_Note (Screen, "cli.history.unknown_kind", []);
                  end if;
               end;
            end if;
         end if;
      end loop;
   end Answer;
begin
   if Word = "/history" then
      With_Store (Answer'Access);
   end if;
end Route_History;

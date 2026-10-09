separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Route_Work is
begin
   if Word = "/work" then
      Command.Action_Argument := T.To_Bounded (Rest (1));
      --  What is typed while the work runs waits until it ends -- a
      --  Ctrl-C that stops the work included, where the terminal would
      --  otherwise throw it away with the interrupt.
      --  Nor shown amid the work's own lines as it is typed: it is
      --  shown when it is taken up, after.
      declare
         Kept : constant Boolean :=
           Hostkit.Terminal_Control.Keep_Input_On_Interrupt (Hostkit.Descriptors.Standard_Input, True);
         Quiet : constant Boolean :=
           Hostkit.Terminal_Control.Set_Echo (Hostkit.Descriptors.Standard_Input, False);

         procedure Restore is
            Ignored : Boolean;
         begin
            if Kept then
               Ignored := Hostkit.Terminal_Control.Keep_Input_On_Interrupt
                 (Hostkit.Descriptors.Standard_Input, False);
            end if;
            if Quiet then
               Ignored := Hostkit.Terminal_Control.Set_Echo (Hostkit.Descriptors.Standard_Input, True);
               Typed_Ahead := True;
            end if;
         end Restore;
         Before_Run : constant Natural := Model_Runner.Platform.Signals.Interrupts;
      begin
         Model_Runner.CLI.Work.Run_With (Command, Screen, Agent, Status);
         Restore;
         --  Stopped with Ctrl-C: what was typed meanwhile is dropped,
         --  as Ctrl-C at the prompt drops it -- not left to become a
         --  message the next command is read into.
         if Model_Runner.Platform.Signals.Interrupts /= Before_Run then
            declare
               --  Something typed, waiting: only then is there anything
               --  dropped to say.
               Pending : constant Boolean :=
                 Hostkit.Descriptors.Wait_Readable (Hostkit.Descriptors.Standard_Input, 0);
               Ignored : Boolean := Hostkit.Terminal_Control.Discard_Input (Hostkit.Descriptors.Standard_Input);
            begin
               if Typed_Ahead and then Pending then
                  Typed_Ahead := False;
                  Pres.Put_Note (Screen, "cli.work.typed_dropped");
               end if;
            end;
         end if;
      exception
         when others =>
            Restore;
            raise;
      end;
      Last_Status := Status;

   end if;
end Route_Work;

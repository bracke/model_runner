with Ada.Strings.Fixed;

package body Model_Runner.Output.Harmony is

   Message : constant String := "<|message|>";

   procedure Show (Self : in out Filter; Text : String) is
      Closed : Boolean;
   begin
      if Text'Length > 0 and then not Self.Shut then
         Emit (Self.Target, Text, Closed);
         Self.Shut := Self.Shut or else Closed;
      end if;
   end Show;

   --  A marker whole, met in a body.
   procedure Marker (Self : in out Filter; Text : String) is
   begin
      if Text in "<|end|>" | "<|call|>" | "<|return|>" then
         if Self.Where = Showing then
            Show (Self, [1 => ASCII.LF]);
         end if;
         Self.Where := In_Header;
      elsif Text in "<|start|>" | "<|channel|>" then
         --  A header opened without the end of the message before it.
         Self.Where := In_Header;
         Self.Held (1 .. Text'Length) := Text;
         Self.Used := Text'Length;
      elsif Self.Where = Showing then
         Show (Self, Text);
      end if;
   end Marker;

   procedure Take (Self : in out Filter; C : Character) is
   begin
      case Self.Where is
         when In_Header =>
            Self.Used := Self.Used + 1;
            Self.Held (Self.Used) := C;
            if Self.Used >= Message'Length
              and then Self.Held (Self.Used - Message'Length + 1 .. Self.Used)
                       = Message
            then
               --  A message addressed to a function is a call: its body is
               --  the arguments, which the run says in its own words.
               Self.Where :=
                 (if Ada.Strings.Fixed.Index
                       (Self.Held (1 .. Self.Used), "to=") > 0
                  then Hiding else Showing);
               Self.Used := 0;
            elsif Self.Used = Self.Held'Length then
               Self.Where := Showing;
               Show (Self, Self.Held (1 .. Self.Used));
               Self.Used := 0;
            end if;

         when Showing | Hiding =>
            if Self.Used = 0 then
               if C = '<' then
                  Self.Used := 1;
                  Self.Held (1) := C;
               elsif Self.Where = Showing then
                  Show (Self, [1 => C]);
               end if;
            elsif Self.Used = 1 and then C /= '|' then
               --  A '<' that opens no marker is text.
               Self.Used := 0;
               if Self.Where = Showing then
                  Show (Self, "<");
               end if;
               Take (Self, C);
            else
               Self.Used := Self.Used + 1;
               Self.Held (Self.Used) := C;
               if Self.Used >= 4
                 and then Self.Held (Self.Used - 1 .. Self.Used) = "|>"
               then
                  declare
                     Text : constant String := Self.Held (1 .. Self.Used);
                  begin
                     Self.Used := 0;
                     Marker (Self, Text);
                  end;
               elsif Self.Used >= Marker_Room then
                  if Self.Where = Showing then
                     Show (Self, Self.Held (1 .. Self.Used));
                  end if;
                  Self.Used := 0;
               end if;
            end if;
      end case;
   end Take;

   overriding procedure Write
     (Self   : in out Filter;
      Item   : String;
      Closed : out Boolean) is
   begin
      for C of Item loop
         Take (Self, C);
      end loop;
      Closed := Self.Shut;
   end Write;

   overriding procedure Flush (Self : in out Filter; Closed : out Boolean) is
   begin
      --  Text held as a header that holds no marker is no header: a reply
      --  ended, or paused, without ever writing one.
      if Self.Where = In_Header and then Self.Used > 0
        and then Ada.Strings.Fixed.Index (Self.Held (1 .. Self.Used), "<|") = 0
      then
         Self.Where := Showing;
         Show (Self, Self.Held (1 .. Self.Used));
         Self.Used := 0;
      end if;
      Flush_Sink (Self.Target, Closed);
      Self.Shut := Self.Shut or else Closed;
      Closed := Self.Shut;
   end Flush;

   overriding function Is_Closed (Self : Filter) return Boolean
   is (Self.Shut
       or else (Self.Target /= null and then Self.Target.Is_Closed));

end Model_Runner.Output.Harmony;

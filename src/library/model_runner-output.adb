package body Model_Runner.Output is

   ----------
   -- Emit --
   ----------

   procedure Emit
     (Item   : Sink_Reference;
      Value  : String;
      Closed : out Boolean) is
   begin
      if Item = null then
         Closed := False;
      else
         Item.all.Write (Value, Closed);
      end if;
   end Emit;

   ----------------
   -- Flush_Sink --
   ----------------

   procedure Flush_Sink (Item : Sink_Reference; Closed : out Boolean) is
   begin
      if Item = null then
         Closed := False;
      else
         Item.all.Flush (Closed);
      end if;
   end Flush_Sink;

   -----------
   -- Write --
   -----------

   overriding procedure Write
     (Self   : in out Null_Sink;
      Item   : String;
      Closed : out Boolean)
   is
      pragma Unreferenced (Self, Item);
   begin
      Closed := False;
   end Write;

   -----------
   -- Flush --
   -----------

   overriding procedure Flush (Self : in out Null_Sink; Closed : out Boolean)
   is
      pragma Unreferenced (Self);
   begin
      Closed := False;
   end Flush;

   ---------------
   -- Is_Closed --
   ---------------

   overriding function Is_Closed (Self : Null_Sink) return Boolean is
      pragma Unreferenced (Self);
   begin
      return False;
   end Is_Closed;

end Model_Runner.Output;

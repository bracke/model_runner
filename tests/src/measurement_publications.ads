--  Consistency of current published timings and their active evidence ledger.
package Measurement_Publications is

   --  @param Table Current README text, with historical observations kept elsewhere.
   --  @param Ledger Active measurement records; archived records do not qualify current claims.
   --  @return True when the device section either publishes no timings and has no active group,
   --    or publishes timings backed by exactly one device group and matching recorded numbers.
   function Device_Table_Consistent (Table, Ledger : String) return Boolean;

end Measurement_Publications;

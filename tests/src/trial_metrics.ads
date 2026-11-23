--  Missing and malformed measurements remain unavailable, never a measured zero.
package Trial_Metrics is

   --  @param Text Native work figures to inspect.
   --  @param Mark Marker before an integer count.
   --  @return Count, or minus one when unavailable or malformed.
   function Count_After (Text, Mark : String) return Long_Long_Integer;

   --  @param Text Native work figures to inspect.
   --  @param Mark Marker before a duration in seconds.
   --  @return Seconds, or minus one when unavailable or malformed.
   function Seconds_After (Text, Mark : String) return Duration;

end Trial_Metrics;

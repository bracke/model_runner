--  Capture native settings frames and the project's resolved configuration.
package Trial_Settings is

   --  @param Transcript Plain native session output, including settings frames.
   --  @param Clean False for absent, malformed, excessive or incomplete native settings.
   --  @return JSON array of native snapshots, or empty on failure.
   function Extract (Transcript : String; Clean : out Boolean) return String;

   --  @param JSON Array of native session and work-call snapshots.
   --  @param Need_Work Whether a successful result must contain an actual root work call.
   --  @return Whether the array satisfies the native reporting contract.
   function Valid (JSON : String; Need_Work : Boolean := False) return Boolean;

   --  @param JSON Native snapshots for one arm, including its initial session.
   --  @param Seed Paired seed required by this attempt.
   --  @param Context_Size Required session and root context capacity.
   --  @param Thinking Required on/off arm choice.
   --  @param Adapters Required number of native runtime attachments.
   --  @return Whether every snapshot preserves the campaign-owned inference controls.
   function Matches
     (JSON : String; Seed, Context_Size : Natural; Thinking : Boolean; Adapters : Natural) return Boolean;

   --  @param Project Initialized project, idle while the parent reads its configuration.
   --  @return Versioned resolved project configuration JSON, or empty when unavailable.
   function Configuration (Project : String) return String;

end Trial_Settings;

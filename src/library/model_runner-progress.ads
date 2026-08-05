with Interfaces;

with Model_Runner.Text;

--  Semantic progress events.
--
--  Runtime packages never print. They report what they are doing as structured
--  events and let an observer decide whether to display anything, in which
--  locale, with which styling and at which rate. The presentation layer
--  installs an observer that throttles and localizes; the tests crate installs
--  one that records events for assertions.
--
--  Task safety: an observer is called from the task that performs the work.
--  Model loading and generation run on the calling task, so an observer only
--  needs to be task safe if the caller shares it between sessions.
package Model_Runner.Progress is

   --  Stages of the model-loading pipeline, in the order they occur.
   type Load_Stage is
     (Opening_Model,
      Reading_Header,
      Reading_Metadata,
      Reading_Tensor_Descriptors,
      Validating_Model,
      Loading_Tokenizer,
      Compiling_Template,
      Selecting_Architecture,
      Selecting_Backend,
      Planning_Memory,
      Preparing_Tensors,
      Converting_Tensor,
      Preparing_Kernels,
      Finalizing_Model,
      Model_Ready);

   --  Points in a generation request that an observer can react to.
   type Generation_Stage is
     (Prompt_Rendered,
      Prompt_Tokenized,
      Prefill_Started,
      Prefill_Progress,
      Generation_Started,
      Token_Produced,
      Generation_Completed);

   type Event_Kind is (Load_Event, Generation_Event);

   --  A progress notification.
   --
   --  Completed and Total describe a countable quantity whose meaning depends
   --  on the stage: tensors for Preparing_Tensors, prompt tokens for
   --  Prefill_Progress, generated tokens for Token_Produced. Total is zero
   --  when the quantity is not known in advance.
   --
   --  Detail carries a machine-readable identifier such as a tensor name. It
   --  is never localized and never contains prompt or generated text.
   type Event (Kind : Event_Kind := Load_Event) is record
      Completed : Interfaces.Unsigned_64 := 0;
      Total     : Interfaces.Unsigned_64 := 0;
      Detail    : Model_Runner.Text.Bounded;
      case Kind is
         when Load_Event =>
            Load : Load_Stage := Opening_Model;
         when Generation_Event =>
            Generation : Generation_Stage := Prompt_Rendered;
      end case;
   end record;

   --  Receiver of progress notifications.
   type Observer is limited interface;

   --  Handle one progress notification.
   --
   --  An observer must not raise. It must not write to the stream that carries
   --  generated output, and it must leave any partially drawn progress line in
   --  a state that the next diagnostic can clear.
   --
   --  @param Self Observer instance.
   --  @param Item Event to handle.
   procedure Notify (Self : in out Observer; Item : Event) is abstract;

   type Observer_Reference is access all Observer'Class;

   --  Send an event to a possibly absent observer.
   --
   --  A null reference discards the event, which is what a caller that wants
   --  no progress reporting expects. Exceptions raised by a faulty observer
   --  are contained here so that reporting progress can never fail the
   --  operation being reported on.
   --
   --  @param Item Observer reference, possibly null.
   --  @param Value Event to deliver.
   procedure Publish (Item : Observer_Reference; Value : Event);

   --  Build a load-stage event.
   --
   --  @param Stage Stage reached.
   --  @param Completed Units finished so far.
   --  @param Total Units expected, or 0 when unknown.
   --  @param Detail Machine-readable identifier, or an empty string.
   --  @return Event ready for Publish.
   function Load_Progress
     (Stage     : Load_Stage;
      Completed : Interfaces.Unsigned_64 := 0;
      Total     : Interfaces.Unsigned_64 := 0;
      Detail    : String := "") return Event;

   --  Build a generation-stage event.
   --
   --  @param Stage Stage reached.
   --  @param Completed Units finished so far.
   --  @param Total Units expected, or 0 when unknown.
   --  @return Event ready for Publish.
   function Generation_Progress
     (Stage     : Generation_Stage;
      Completed : Interfaces.Unsigned_64 := 0;
      Total     : Interfaces.Unsigned_64 := 0) return Event;

end Model_Runner.Progress;

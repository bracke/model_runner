--  Cooperative cancellation.
--
--  Cancellation is requested from outside the computation -- a signal handler,
--  an interactive front end or a test -- and observed inside it at bounded
--  intervals. Nothing is aborted asynchronously: a computation that observes a
--  request unwinds through its normal failure path, so a cancelled model load
--  releases every resource it acquired and a cancelled token evaluation leaves
--  the KV cache without a committed position.
--
--  Observation points. The parser checks between sections and between tensors,
--  preparation checks before and after each large allocation and between
--  tensor conversions, and generation checks between prompt batches, between
--  layers and between generated tokens. The documented worst-case latency is
--  therefore one transformer layer of one token.
--
--  Task safety: Token is a protected type and may be shared between the
--  requesting task and every worker.
package Model_Runner.Cancellation is

   --  A cancellation flag shared by a requester and its observers.
   protected type Token is

      --  Request cancellation. Repeated requests are counted so that a front
      --  end can escalate on a second interrupt.
      procedure Request;

      --  Clear the request so the token can be reused for the next operation.
      procedure Reset;

      --  Report whether cancellation has been requested.
      --
      --  @return True once Request has been called and Reset has not.
      function Is_Requested return Boolean;

      --  Number of requests since the last Reset.
      --
      --  @return Request count.
      function Request_Count return Natural;

   private
      Requested : Boolean := False;
      Requests  : Natural := 0;
   end Token;

   type Token_Reference is access all Token;

   --  Report whether a possibly absent token has been cancelled.
   --
   --  A null reference means the operation cannot be cancelled, which is the
   --  behaviour a caller that supplies no token expects.
   --
   --  @param Item Token reference, possibly null.
   --  @return True when Item is present and cancellation was requested.
   function Is_Cancelled (Item : Token_Reference) return Boolean;

end Model_Runner.Cancellation;

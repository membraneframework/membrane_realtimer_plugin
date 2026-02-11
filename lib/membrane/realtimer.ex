defmodule Membrane.Realtimer do
  @moduledoc """
  Sends buffers to the output in real time, according to buffers' timestamps.

  If buffers come in slower than realtime, they're sent as they come in.

  It can be reset by sending `%#{inspect(__MODULE__)}.Events.Reset{}` event on its input pad.
  """
  use Membrane.Filter

  alias __MODULE__.Events
  alias Membrane.Buffer

  def_input_pad :input,
    accepted_format: _any,
    flow_control: :manual,
    demand_unit: :buffers

  def_output_pad :output,
    accepted_format: _any,
    flow_control: :push

  def_options latency: [
                spec: Membrane.Time.non_neg(),
                default: 0,
                description: """
                Artificial latency that this element will add to the stream. The purpose of this it
                to handle cases where the incoming stream can get lagged, for example when an
                element up the pipeline can get held up for some time and then produce all the
                "late" buffers at once. The latency gives Realtimer some margin in waiting
                for those "late" buffers, so that the outgoing stream is still smooth.
                """
              ]

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            reference_timestamps:
              %{
                system: Membrane.Time.non_neg(),
                stream: Membrane.Time.non_neg()
              }
              | :to_be_determined,
            pending_actions: [Membrane.Element.Action.t()]
          }

    @enforce_keys [:latency]

    defstruct @enforce_keys ++
                [
                  reference_timestamps: :to_be_determined,
                  pending_actions: []
                ]
  end

  @impl true
  def handle_init(_ctx, opts) do
    {[], %State{latency: opts.latency}}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[demand: :input], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, %State{} = state) do
    state =
      if state.reference_timestamps == :to_be_determined do
        %State{
          state
          | reference_timestamps: %{
              system: Membrane.Time.monotonic_time(),
              stream: Buffer.get_dts_or_pts(buffer)
            }
        }
      else
        state
      end

    buffer_relative_timestamp = Buffer.get_dts_or_pts(buffer) - state.reference_timestamps.stream
    target_time = state.reference_timestamps.system + buffer_relative_timestamp + state.latency

    interval =
      (target_time - Membrane.Time.monotonic_time())
      |> max(0)
      |> Membrane.Time.as_milliseconds(:round)

    Process.send_after(self(), :execute_pending_actions, interval)

    state = %State{
      state
      | pending_actions: [{:buffer, {:output, buffer}} | state.pending_actions]
    }

    {[], state}
  end

  @impl true
  def handle_info(:execute_pending_actions, ctx, %State{} = state) do
    actions =
      Enum.reverse(state.pending_actions) ++
        if ctx.pads.input.end_of_stream?, do: [], else: [demand: :input]

    {actions, %State{state | pending_actions: []}}
  end

  @impl true
  def handle_event(:input, %Events.Reset{}, _ctx, %State{} = state) do
    {[], %State{state | reference_timestamps: :to_be_determined}}
  end

  @impl true
  def handle_event(pad, event, _ctx, %State{pending_actions: pending_actions} = state)
      when pad == :output or pending_actions == [] do
    {[forward: event], state}
  end

  @impl true
  def handle_event(:input, event, _ctx, %State{} = state) do
    {[], %State{state | pending_actions: [{:event, {:output, event}} | state.pending_actions]}}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, %State{pending_actions: []} = state) do
    {[forward: stream_format], state}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, %State{} = state) do
    {[],
     %State{
       state
       | pending_actions: [{:stream_format, {:output, stream_format}} | state.pending_actions]
     }}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %State{pending_actions: []} = state) do
    {[end_of_stream: :output], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %State{} = state) do
    {[], %State{state | pending_actions: [{:end_of_stream, :output} | state.pending_actions]}}
  end
end

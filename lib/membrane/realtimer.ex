defmodule Membrane.Realtimer do
  @moduledoc """
  Sends buffers to the output in real time, according to buffers' timestamps.

  If buffers come in slower than realtime, they're sent as they come in.

  It can be reset by sending `%#{inspect(__MODULE__)}.Events.Reset{}` event on its input pad.
  """
  use Membrane.Filter

  alias __MODULE__.Events
  alias Membrane.Buffer

  def_input_pad :input, accepted_format: _any, flow_control: :manual, demand_unit: :buffers
  def_output_pad :output, accepted_format: _any, flow_control: :push

  def_options latency: [
                spec: Membrane.Time.non_neg(),
                default: 0,
                description: """
                Inital latency lol
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
              | :not_set,
            tick_actions: [Membrane.Element.Action.t()]
          }

    @enforce_keys [:latency]

    defstruct @enforce_keys ++
                [
                  reference_timestamps: :not_set,
                  tick_actions: []
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
  def handle_buffer(:input, buffer, _ctx, state = %State{}) do
    state =
      if state.reference_timestamps == :not_set do
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

    delta_timestamp = Buffer.get_dts_or_pts(buffer) - state.reference_timestamps.stream
    target_time = state.reference_timestamps.system + delta_timestamp + state.latency

    interval =
      (target_time - Membrane.Time.monotonic_time())
      |> max(0)
      |> Membrane.Time.as_milliseconds(:round)

    Process.send_after(self(), :tick, interval)

    state = %State{
      state
      | tick_actions: [{:buffer, {:output, buffer}} | state.tick_actions]
    }

    {[], state}
  end

  @impl true
  def handle_info(:tick, ctx, %State{} = state) do
    actions =
      Enum.reverse(state.tick_actions) ++
        if ctx.pads.input.end_of_stream?, do: [], else: [demand: :input]

    {actions, %State{state | tick_actions: []}}
  end

  @impl true
  def handle_event(:input, %Events.Reset{}, _ctx, %State{} = state) do
    {[], %State{state | reference_timestamps: :not_set}}
  end

  @impl true
  def handle_event(pad, event, _ctx, %State{tick_actions: tick_actions} = state)
      when pad == :output or tick_actions == [] do
    {[forward: event], state}
  end

  @impl true
  def handle_event(:input, event, _ctx, %State{} = state) do
    {[], %State{state | tick_actions: [{:event, {:output, event}} | state.tick_actions]}}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, %State{tick_actions: []} = state) do
    {[forward: stream_format], state}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, %State{} = state) do
    {[],
     %State{
       state
       | tick_actions: [{:stream_format, {:output, stream_format}} | state.tick_actions]
     }}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %State{tick_actions: []} = state) do
    {[end_of_stream: :output], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %State{} = state) do
    {[], %State{state | tick_actions: [{:end_of_stream, :output} | state.tick_actions]}}
  end
end

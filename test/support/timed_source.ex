defmodule Membrane.Realtimer.TimedSource do
  @moduledoc false
  use Membrane.Source

  @type instruction ::
          {:buffer, Membrane.Buffer.t()}
          | {:event, Membrane.Event.t()}
          | {:sleep, Membrane.Time.non_neg()}

  def_output_pad :output, accepted_format: _any, flow_control: :push

  def_options instructions: [
                spec: [instruction()]
              ]

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{instructions: opts.instructions}}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {actions, rest_of_instructions} = get_actions_to_execute(state.instructions)

    {
      [stream_format: {:output, %Membrane.RemoteStream{}}] ++ actions,
      %{state | instructions: rest_of_instructions}
    }
  end

  @impl true
  def handle_info(:sleep_finished, _ctx, state) do
    {actions, rest_of_instructions} = get_actions_to_execute(state.instructions)

    {actions, %{state | instructions: rest_of_instructions}}
  end

  defp get_actions_to_execute(instructions) do
    {instructions_to_execute, rest_of_instructions} =
      Enum.split_while(instructions, fn
        {:sleep, _time} -> false
        {_intruction, _arg} -> true
      end)

    {maybe_eos, rest_of_instructions} =
      case rest_of_instructions do
        [{:sleep, sleep_duration} | rest_of_instructions] ->
          Process.send_after(
            self(),
            :sleep_finished,
            Membrane.Time.as_milliseconds(sleep_duration, :round)
          )

          {[], rest_of_instructions}

        [] ->
          {[end_of_stream: :output], []}
      end

    actions =
      Enum.map(instructions_to_execute, fn
        {:buffer, buffer} -> {:buffer, {:output, buffer}}
        {:event, event} -> {:event, {:output, event}}
      end)

    {actions ++ maybe_eos, rest_of_instructions}
  end
end

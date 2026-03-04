defmodule Membrane.RealtimerTest do
  use ExUnit.Case

  import Membrane.Testing.Assertions
  import Membrane.ChildrenSpec

  alias Membrane.{Buffer, Realtimer, Testing, Time}
  alias Membrane.Realtimer.Events.Reset

  test "Limits playback speed to realtime" do
    instructions = [
      buffer: {0, 0},
      buffer: {1, 200},
      buffer: {2, 400},
      buffer: {3, 600},
      buffer: {4, 800}
    ]

    assertions = [
      assert: {0, 20},
      refute: 190,
      assert: {1, 20},
      refute: 190,
      assert: {2, 20},
      refute: 190,
      assert: {3, 20},
      refute: 190,
      assert: {4, 20}
    ]

    test_scenario(instructions, assertions, 0)
  end

  test "Limits playback to realtime with max_latency set" do
    instructions = [
      buffer: {0, 0},
      buffer: {1, 200},
      buffer: {2, 400},
      buffer: {3, 600},
      buffer: {4, 800}
    ]

    assertions = [
      assert: {0, 20},
      refute: 190,
      assert: {1, 20},
      refute: 190,
      assert: {2, 20},
      refute: 190,
      assert: {3, 20},
      refute: 190,
      assert: {4, 20}
    ]

    test_scenario(instructions, assertions, Time.milliseconds(500))
  end

  test "Correctly reacts to Reset event" do
    instructions =
      [
        buffer: {0, 0},
        buffer: {1, 200},
        event: :reset,
        buffer: {2, 0},
        buffer: {3, 200}
      ]

    assertions = [
      assert: {0, 20},
      refute: 190,
      assert: {1, 20},
      assert: {2, 20},
      refute: 190,
      assert: {3, 20}
    ]

    test_scenario(instructions, assertions, 0)
  end

  test "Correctly reacts to Reset event with latency set" do
    instructions =
      [
        buffer: {0, 0},
        buffer: {1, 200},
        event: :reset,
        buffer: {2, 400},
        buffer: {3, 600}
      ]

    assertions = [
      assert: {0, 20},
      refute: 190,
      assert: {1, 20},
      assert: {2, 20},
      refute: 190,
      assert: {3, 20}
    ]

    test_scenario(instructions, assertions, Time.milliseconds(500))
  end

  test "Corretly reacts to realtime input with max_latency set" do
    instructions = [
      buffer: {0, 0},
      sleep: 200,
      buffer: {1, 200},
      sleep: 200,
      buffer: {2, 400},
      sleep: 200,
      buffer: {3, 600},
      sleep: 200,
      buffer: {4, 800}
    ]

    assertions = [
      refute: 490,
      assert: {0, 20},
      refute: 190,
      assert: {1, 20},
      refute: 190,
      assert: {2, 20},
      refute: 190,
      assert: {3, 20},
      refute: 190,
      assert: {4, 20}
    ]

    test_scenario(instructions, assertions, Time.milliseconds(500))
  end

  test "Correctly reacts to laggy realtime input" do
    instructions = [
      buffer: {0, 0},
      sleep: 200,
      buffer: {1, 200},
      sleep: 200,
      buffer: {2, 400},
      sleep: 200,
      buffer: {3, 600},
      sleep: 400,
      buffer: {4, 800},
      buffer: {5, 1000},
      sleep: 200,
      buffer: {6, 1200}
    ]

    assertions = [
      refute: 490,
      assert: {0, 20},
      refute: 190,
      assert: {1, 20},
      refute: 190,
      assert: {2, 20},
      refute: 190,
      assert: {3, 20},
      refute: 190,
      assert: {4, 20},
      refute: 190,
      assert: {5, 20}
    ]

    test_scenario(instructions, assertions, Time.milliseconds(500))
  end

  test "Correctly reacts to laggy non-realtime input" do
    instructions = [
      buffer: {0, 0},
      buffer: {1, 200},
      buffer: {2, 400},
      buffer: {3, 600},
      sleep: 200,
      buffer: {4, 800},
      sleep: 400,
      buffer: {5, 1000}
    ]

    assertions = [
      assert: {0, 20},
      refute: 190,
      assert: {1, 20},
      refute: 190,
      assert: {2, 20},
      refute: 190,
      assert: {3, 20},
      refute: 190,
      assert: {4, 20},
      refute: 190,
      assert: {5, 20}
    ]

    test_scenario(instructions, assertions, Time.milliseconds(500))
  end

  test "Correctly reacts to laggy realtime input with reset events" do
    instructions = [
      buffer: {0, 0},
      sleep: 200,
      buffer: {1, 200},
      sleep: 200,
      buffer: {2, 400},
      sleep: 400,
      buffer: {3, 600},
      buffer: {4, 800},
      sleep: 200,
      buffer: {5, 1000},
      event: :reset,
      buffer: {6, 0},
      sleep: 200,
      buffer: {7, 200},
      sleep: 400,
      buffer: {8, 400},
      buffer: {9, 600}
    ]

    assertions = [
      refute: 490,
      assert: {0, 20},
      refute: 190,
      assert: {1, 20},
      refute: 190,
      assert: {2, 20},
      refute: 190,
      assert: {3, 20},
      refute: 190,
      assert: {4, 20},
      refute: 190,
      assert: {5, 20},
      assert: {6, 20},
      refute: 190,
      assert: {7, 20},
      refute: 190,
      assert: {8, 20}
    ]

    test_scenario(instructions, assertions, Time.milliseconds(500))
  end

  test "Correctly reacts to reset events during offset calculation" do
    instructions = [
      buffer: {0, 0},
      sleep: 200,
      buffer: {1, 200},
      sleep: 200,
      buffer: {2, 400},
      event: :reset,
      buffer: {3, 0},
      sleep: 200,
      buffer: {4, 200},
      sleep: 200,
      buffer: {5, 400}
    ]

    assertions = [
      refute: 690,
      assert: {0, 20},
      refute: 190,
      assert: {1, 20},
      refute: 190,
      assert: {2, 20},
      assert: {3, 20},
      refute: 190,
      assert: {4, 20},
      refute: 190,
      assert: {5, 20}
    ]

    test_scenario(instructions, assertions, Time.milliseconds(700))
  end

  defp test_scenario(instructions, assertions, max_latency) do
    spec =
      child(:src, %Membrane.Realtimer.TimedSource{instructions: instructions})
      |> child(:realtimer, %Realtimer{max_latency: max_latency})
      |> child(:sink, Testing.Sink)

    pipeline = Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_sink_stream_format(pipeline, :sink, _stream_format)

    Enum.each(assertions, fn
      {:assert, {payload, timeout}} ->
        assert_sink_buffer(pipeline, :sink, %Buffer{payload: ^payload}, timeout)

      {:refute, timeout} ->
        refute_sink_buffer(pipeline, :sink, _buffer, timeout)
    end)

    assert_end_of_stream(pipeline, :sink)
    Testing.Pipeline.terminate(pipeline)
  end
end

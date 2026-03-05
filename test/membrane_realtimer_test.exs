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

  test "Correctly reacts to stream lagging multiple times" do
    instructions =
      Enum.flat_map(0..35//6, fn seq ->
        [
          buffer: {seq, seq * 200},
          sleep: 200,
          buffer: {seq + 1, (seq + 1) * 200},
          sleep: 200,
          buffer: {seq + 2, (seq + 2) * 200},
          sleep: 600,
          buffer: {seq + 3, (seq + 3) * 200},
          buffer: {seq + 4, (seq + 4) * 200},
          buffer: {seq + 5, (seq + 5) * 200},
          sleep: 200
        ]
      end)

    assertions =
      [refute: 690] ++
        Enum.flat_map(0..35, fn seq ->
          [
            assert: {seq, 20},
            refute: 190
          ]
        end)

    test_scenario(instructions, assertions, Time.milliseconds(700))
  end

  test "Correctly reacts to multiple reset events" do
    instructions =
      Enum.flat_map(0..23//4, fn seq ->
        [
          buffer: {seq, seq * 3 * 200},
          sleep: 200,
          buffer: {seq + 1, (seq * 3 + 1) * 200},
          sleep: 200,
          buffer: {seq + 2, (seq * 3 + 2) * 200},
          sleep: 200,
          buffer: {seq + 3, (seq * 3 + 3) * 200},
          event: :reset
        ]
      end)
      |> IO.inspect()

    assertions =
      [refute: 590] ++
        Enum.flat_map(0..23//4, fn seq ->
          [
            assert: {seq, 20},
            refute: 190,
            assert: {seq + 1, 20},
            refute: 190,
            assert: {seq + 2, 20},
            refute: 190,
            assert: {seq + 3, 20}
          ]
        end)

    test_scenario(instructions, assertions, Time.milliseconds(600))
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

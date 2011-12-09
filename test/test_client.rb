# -*- encoding: utf-8 -*-

$:.unshift(File.dirname(__FILE__))

require 'test_helper'

class TestClient < Test::Unit::TestCase
  include TestBase
  
  def setup
    @client = get_client()
    # Multi_thread test data
    @max_threads = 20
    @max_msgs = 50
  end

  def teardown
    @client.close if @client.open? # allow tests to close
  end

  def test_ack_api_works
    @client.publish make_destination, message_text, {:suppress_content_length => true}

    received = nil
    @client.subscribe(make_destination, {:ack => 'client'}) {|msg| received = msg}
    sleep 0.01 until received
    assert_equal message_text, received.body
    receipt = nil
    ack_headers = {}
    if @client.protocol > Stomp::SPL_10
      ack_headers["subscription"] = received.headers["subscription"]
    end
    @client.acknowledge(received, ack_headers) {|r| receipt = r}
    sleep 0.01 until receipt
    assert_not_nil receipt.headers['receipt-id']
  end unless ENV['STOMP_RABBIT']

  def test_asynch_subscribe
    received = false
    @client.subscribe(make_destination) {|msg| received = msg}
    @client.publish make_destination, message_text
    sleep 0.01 until received

    assert_equal message_text, received.body
  end

  def test_noack
    @client.publish make_destination, message_text

    received = nil
    @client.subscribe(make_destination, :ack => :client) {|msg| received = msg}
    sleep 0.01 until received
    assert_equal message_text, received.body
    @client.close

    # was never acked so should be resent to next client

    @client = Stomp::Client.new(user, passcode, host, port)
    received2 = nil
    @client.subscribe(make_destination) {|msg| received2 = msg}
    sleep 0.01 until received2

    assert_equal message_text, received2.body
    assert_equal received.body, received2.body
    assert_equal received.headers['message-id'], received2.headers['message-id'] unless ENV['STOMP_RABBIT']
  end

  def test_receipts
    receipt = false
    @client.publish(make_destination, message_text) {|r| receipt = r}
    sleep 0.1 until receipt

    message = nil
    @client.subscribe(make_destination) {|m| message = m}
    sleep 0.1 until message
    assert_equal message_text, message.body
  end

  def test_disconnect_receipt
    @client.close :receipt => "xyz789"
    assert_nothing_raised {
      assert_not_nil(@client.disconnect_receipt, "should have a receipt")
      assert_equal(@client.disconnect_receipt.headers['receipt-id'],
        "xyz789", "receipt sent and received should match")
    }
  end

  def test_publish_then_sub
    @client.publish make_destination, message_text
    message = nil
    @client.subscribe(make_destination) {|m| message = m}
    sleep 0.01 until message

    assert_equal message_text, message.body
  end

  def test_subscribe_requires_block
    assert_raise(RuntimeError) do
      @client.subscribe make_destination
    end
  end

  def test_transactional_publish
    @client.begin 'tx1'
    @client.publish make_destination, message_text, :transaction => 'tx1'
    @client.commit 'tx1'

    message = nil
    @client.subscribe(make_destination) {|m| message = m}
    sleep 0.01 until message

    assert_equal message_text, message.body
  end

  def test_transaction_publish_then_rollback
    @client.begin 'tx1'
    @client.publish make_destination, "first_message", :transaction => 'tx1'
    @client.abort 'tx1'

    @client.begin 'tx1'
    @client.publish make_destination, "second_message", :transaction => 'tx1'
    @client.commit 'tx1'

    message = nil
    @client.subscribe(make_destination) {|m| message = m}
    sleep 0.01 until message
    assert_equal "second_message", message.body
  end

  def test_transaction_ack_rollback_with_new_client
    @client.publish make_destination, message_text

    @client.begin 'tx1'
    message = nil
    @client.subscribe(make_destination, :ack => 'client') {|m| message = m}
    sleep 0.01 until message
    assert_equal message_text, message.body
    @client.acknowledge message, :transaction => 'tx1'
    message = nil
    @client.abort 'tx1'

    # lets recreate the connection
    teardown
    setup
    @client.subscribe(make_destination, :ack => 'client') {|m| message = m}

    Timeout::timeout(4) do
      sleep 0.01 until message
    end
    assert_not_nil message
    assert_equal message_text, message.body

    @client.begin 'tx2'
    @client.acknowledge message, :transaction => 'tx2'
    @client.commit 'tx2'
  end

  def test_raise_on_multiple_subscriptions_to_same_make_destination
    subscribe_dest = make_destination
    @client.subscribe(subscribe_dest) {|m| nil }
    assert_raise(RuntimeError) do
      @client.subscribe(subscribe_dest) {|m| nil }
    end
  end

  def test_raise_on_multiple_subscriptions_to_same_id
    subscribe_dest = make_destination
    @client.subscribe(subscribe_dest, {'id' => 'myid'}) {|m| nil }
    assert_raise(RuntimeError) do
      @client.subscribe(subscribe_dest, {'id' => 'myid'}) {|m| nil }
    end
  end

  def test_raise_on_multiple_subscriptions_to_same_id_mixed
    subscribe_dest = make_destination
    @client.subscribe(subscribe_dest, {'id' => 'myid'}) {|m| nil }
    assert_raise(RuntimeError) do
      @client.subscribe(subscribe_dest, {:id => 'myid'}) {|m| nil }
    end
  end

  def  test_asterisk_wildcard_subscribe
    queue_base_name = make_destination
    queue1 = queue_base_name + ".a"
    queue2 = queue_base_name + ".b"
    send_message = message_text
    @client.publish queue1, send_message
    @client.publish queue2, send_message
    messages = []
    @client.subscribe(queue_base_name + ".*", :ack => 'client') do |m|
      messages << m
      @client.acknowledge(m)
    end
    Timeout::timeout(4) do
      sleep 0.1 while messages.size < 2
    end

    messages.each do |message|
      assert_not_nil message
      assert_equal send_message, message.body
    end
    results = [queue1, queue2].collect do |queue|
      messages.any? do |message| 
        message_source = message.headers['destination']
        message_source == queue
      end
    end
    assert results.all?{|a| a == true }

  end unless ENV['STOMP_NOWILD']

  def test_greater_than_wildcard_subscribe
    queue_base_name = make_destination + "."
    queue1 = queue_base_name + "foo.a"
    queue2 = queue_base_name + "bar.a"
    queue3 = queue_base_name + "foo.b"
    send_message = message_text
    @client.publish queue1, send_message
    @client.publish queue2, send_message
    @client.publish queue3, send_message
    messages = []
    # should subscribe to all three queues
    @client.subscribe(queue_base_name + ">", :ack => 'client') do |m|
      messages << m
      @client.acknowledge(m)
    end
    Timeout::timeout(4) do
      sleep 0.1 while messages.size < 3
    end

    messages.each do |message|
      assert_not_nil message
      assert_equal send_message, message.body
    end
    # make sure that the messages received came from the expected queues
    results = [queue1, queue2, queue3].collect do |queue|
      messages.any? do |message| 
        message_source = message.headers['destination']
        message_source == queue
      end
    end
    assert results.all?{|a| a == true }
  end unless ENV['STOMP_NOWILD'] || ENV['STOMP_DOTQUEUE']

  def test_transaction_with_client_side_redelivery
    @client.publish make_destination, message_text

    @client.begin 'tx1'
    message = nil
    @client.subscribe(make_destination, :ack => 'client') { |m| message = m }

    sleep 0.1 while message.nil?

    assert_equal message_text, message.body
    @client.acknowledge message, :transaction => 'tx1'
    message = nil
    @client.abort 'tx1'

    sleep 0.1 while message.nil?

    assert_not_nil message
    assert_equal message_text, message.body

    @client.begin 'tx2'
    @client.acknowledge message, :transaction => 'tx2'
    @client.commit 'tx2'
  end

  def test_connection_frame
  	assert_not_nil @client.connection_frame
  end

  def test_unsubscribe
    message = nil
    dest = make_destination
    to_send = message_text
    client = Stomp::Client.new(user, passcode, host, port, true)
    assert_nothing_raised {
      client.subscribe(dest, :ack => 'client') { |m| message = m }
      @client.publish dest, to_send
      Timeout::timeout(4) do
        sleep 0.01 until message
      end
    }
    assert_equal to_send, message.body, "first body check"
    assert_nothing_raised {
      client.unsubscribe dest # was throwing exception on unsub at one point
      client.close
    }
    #  Same message should remain on the queue.  Receive it again with ack=>auto.
    message_copy = nil
    client = Stomp::Client.new(user, passcode, host, port, true)
    assert_nothing_raised {
      client.subscribe(dest, :ack => 'auto') { |m| message_copy = m }
      Timeout::timeout(4) do
        sleep 0.01 until message_copy
      end
    }
    assert_equal to_send, message_copy.body, "second body check"
    assert_equal message.headers['message-id'], message_copy.headers['message-id'], "header check" unless ENV['STOMP_RABBIT']
  end

  def test_thread_one_subscribe
    msg = nil
    dest = make_destination
    Thread.new(@client) do |acli|
      assert_nothing_raised {
        acli.subscribe(dest) { |m| msg = m }
        Timeout::timeout(4) do
          sleep 0.01 until msg
        end
      }
    end
    #
    @client.publish(dest, message_text)
    sleep 1
    assert_not_nil msg
  end

  def test_thread_multi_subscribe
    #
    lock = Mutex.new
    msg_ctr = 0
    dest = make_destination
    1.upto(@max_threads) do |tnum|
      # Threads within threads .....
      Thread.new(@client) do |acli|
        assert_nothing_raised {
          acli.subscribe(dest) { |m| 
            msg = m
            lock.synchronize do
              msg_ctr += 1
            end
            # Simulate message processing
            sleep 0.05
          }
        }
      end
    end
    #
    1.upto(@max_msgs) do |mnum|
      msg = Time.now.to_s + " #{mnum}"
      @client.publish(dest, message_text)
    end
    #
    max_sleep = (RUBY_VERSION =~ /1\.8\.6/) ? 30 : 5
    sleep_incr = 0.10
    total_slept = 0
    while true
      break if @max_msgs == msg_ctr
      total_slept += sleep_incr
      break if total_slept > max_sleep
      sleep sleep_incr
    end
    assert_equal @max_msgs, msg_ctr
  end

  def test_closed_checks_client
    @client.close
    #
    assert_raise Stomp::Error::NoCurrentConnection do
      m = Stomp::Message.new("")
      @client.acknowledge(m) {|r| receipt = r}
    end
    #
    assert_raise Stomp::Error::NoCurrentConnection do
      @client.begin("dummy_data")
    end
    #
    assert_raise Stomp::Error::NoCurrentConnection do
      @client.commit("dummy_data")
    end
    #
    assert_raise Stomp::Error::NoCurrentConnection do
      @client.abort("dummy_data")
    end
    #
    assert_raise Stomp::Error::NoCurrentConnection do
      @client.subscribe("dummy_data", {:ack => 'auto'}) {|msg| received = msg}
    end
    #
    assert_raise Stomp::Error::NoCurrentConnection do
      @client.unsubscribe("dummy_data")
    end
    #
    assert_raise Stomp::Error::NoCurrentConnection do
      @client.publish("dummy_data","dummy_data")
    end
    #
    assert_raise Stomp::Error::NoCurrentConnection do
      @client.unreceive("dummy_data")
    end
    #
    assert_raise Stomp::Error::NoCurrentConnection do
      @client.close("dummy_data")
    end
  end

  private
    def message_text
      name = caller_method_name unless name
      "test_client#" + name
    end
end

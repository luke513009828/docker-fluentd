# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

module Qpid
  module Proton

    # Read AMQP data from an IO, call on_* methods on a Handler, and write AMQP
    # data generated by the #connection to the IO.
    #
    # Thread unsafe: intended for integration with IO frameworks that wait for
    # IO availability and serialize the use of each connection.
    #
    # ConnectionRunner uses is a simple way to run a single connection using an engine.
    #
    class ConnectionEngine

      class RemoteCloseError < ProtonError; end

      # FIXME aconway 2015-12-02: setting connection options.

      # Read/write an IO object and dispatch AMQP events to a
      # Qpid::Proton::Event::Handler.
      def initialize io, handler=nil
        # Default to a basic MessagingHandler for default behaviors.
        @handler = handler || Handler::MessagingHandler.new
        @io = io
        @collector = Event::Collector.new
        @transport = Transport.new
        @connection = Connection.new
        @connection.collect(@collector)
        @transport.bind(@connection)
      end

      attr_reader :connection, :handler, :io

      # Can be converted to the underlying IO object and used in select()
      def to_io
        @io
      end

      # True if the engine is ready to read data.
      def can_read?
        return @transport.capacity > 0
      end

      # True if the engine is ready to write data.
      def can_write?
        return @transport.pending > 0
      end

      # Read, write and process available data and events without blocking.
      # Raises RemoteCloseError if the remote end sends an AMQP close with an error.
      # Raises IOError if the connection closes due to an IO error.
      def process
        if !closed?
          try_write if can_write?
          try_read if can_read?
          dispatch
          # 3 ways we can close: remote AMQP close, local IO closed or both sides
          # of transport closed by try_read and try_write
          if @connection.remote_closed? || @io.closed? || @transport.closed?
            disconnect
            if @connection.remote_closed? # AMQP close
              c = @connection.remote_condition
              raise RemoteCloseError.new(c) if c
            else
              raise (@io_error ? @io_error : IOError.new("stream closed"))
            end
          end
        end
      end

      def closed?
        return @transport.closed?
      end

      # Disconnect the engine's IO, process final shutdown events.
      def disconnect
        return if closed?
        try_write while can_write?
        @io.close rescue nil
        @transport.close_head
        @transport.close_tail
        dispatch                # Final events.
      end

      private

      # dispatch all events in the collector
      def dispatch
        while event = @collector.peek
          # FIXME aconway 2015-12-10: move this to initialize
          # Synthesize on_start event.
          @handler.on_start(event) if event.type == Qpid::Proton::Event::CONNECTION_INIT
          event.dispatch(@handler)
          @collector.pop
        end
      end

      def try_read
        data = @io.read_nonblock(@transport.capacity)
        @transport.push(data) if !data.empty?
      rescue IO::WaitReadable, Errno::EINTR
      # Re-try
      rescue EOFError
        @transport.close_tail
      rescue Exception => e
        @io_error ||= e
        @transport.close_tail
      end

      def try_write
        data = @transport.peek(@transport.pending)
        begin
          @transport.pop @io.write_nonblock(data)
        rescue IO::WaitWritable, Errno::EINTR
        # Ignore
        rescue Errno::EBADF     # Can't use write_nonblock, fall back to write
          @transport.pop @io.write(data)
        end
      rescue EOFError
        @transport.close_head
      rescue Exception => e
        @io_error ||= e
        @transport.close_head
      end
    end

    # Handle the IO blocking for a single ConnectionEngine, provide thread-safe access.
    # Optional block is passed the engine to set things up.
    class ConnectionDriver

      def initialize io, handler=nil
        @engine = ConnectionEngine.new io, handler
        @lock = Mutex.new
        @wake_rd, @wake_wr = IO.pipe
        yield @engine if block_given?
      end

      # The engine's IO. Closing it will stop the runner.
      def io; @engine.io end

      # Run the connection, return when it is closed.
      #
      # Optional block means run until the block yields true, raise EOFError if
      # engine closes before that happens.
      #
      # Optional timeout means raise TimeoutError if IO blocks for more than timeout.
      #
      def run timeout=nil
        while true
          @lock.synchronize do
            @engine.process
            if block_given?
              return if yield
              raise EOFError if @engine.closed?
            else
              return if @engine.closed?
            end
            @r = [@wake_rd]
            @r << @engine if @engine.can_read?
            @w = [@engine] if @engine.can_write?
          end
          ok = IO.select(@r , @w, nil, timeout)
          @lock.synchronize do
            if !ok
              @engine.close
              raise TimeoutError
            else                # Drain wakeup, we will do another process before select.
              while @wake_rd.read_nonblock(1024).size; end rescue nil
            end
          end
        end
      ensure
        if @engine.closed?
          @wake_rd.close
          @wake_wr.close
        end
      end

      # Safely execute a block that needs to use the engine or it's connection
      # objects from a thread that is not calling #run. The engine is passed to
      # the block. Do not use from a handler method.
      # Raises EOFError if the engine is closed, or any exception raised by the block.
      # FIXME aconway 2015-12-10: rename run/connection? Access to connection only?
      def synchronize
        @lock.synchronize do
          raise EOFError.new "connection closed" if @engine.closed?
          yield @engine
          @wake_wr << 'x'
        end
      end

      # Disconnect the driver if it is not already disconnected. Will cause #run to exit.
      def disconnect
        io.close unless io.closed?
      end

      def closed?
        @lock.synchronize @engine.closed
      end
    end

    class Connection
      def open_session
        s = Session.wrap(Cproton.pn_session(@impl))
        s.open
        return s
      end

      # TODO aconway 2015-12-03: git rid of ambiguous #session.
      def default_session
        @default_session ||= open_session
        return @default_session
      end

      def open_sender(*args, &block) default_session.open_sender(*args, &block) end
      def open_receiver(*args, &block) default_session.open_receiver(*args, &block) end
    end

    class Session
      def open_receiver(source, opts = {})
        # FIXME aconway 2015-12-02: link IDs.
        receiver = receiver(opts[:name] || SecureRandom.uuid)
        receiver.source.address ||= source || opts[:source]
        receiver.target.address ||= opts[:target]
        receiver.source.dynamic = true if opts[:dynamic]
        # FIXME aconway 2015-12-02: separate handlers per link?
        # FIXME aconway 2015-12-02: link options
        receiver.open
        return receiver
      end

      def open_sender(target, opts = {})
        # FIXME aconway 2015-12-02: link IDs.
        sender = sender(opts[:name] || SecureRandom.uuid)
        sender.target.address ||= target || opts[:target]
        sender.source.address ||= opts[:source]
        sender.target.dynamic = true if opts[:dynamic]
        # FIXME aconway 2015-12-02: separate handlers per link?
        # FIXME aconway 2015-12-02: link options
        sender.open
        return sender
      end
    end

    module Event
      class Collector
        def put(context, event_type)
          Cproton.pn_collector_put(@impl, Cproton.pn_class(context.impl), context.impl, event_type.number)
        end
      end
    end

    module Reactor

      class Backoff

        def initialize min_, max_
          @min = min_ > 0 ? min_ : 0.1
          @max = [max_, min_].max
          reset
        end

        def reset
          @delay = 0
        end

        def next
          current = @delay
          @delay = @delay.zero? ? @min : [@max, 2 * @delay].min
          return current
        end
      end

    end
  end
end

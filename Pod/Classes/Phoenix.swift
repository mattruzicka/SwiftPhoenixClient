//
//  Phoenix.swift
//  SwiftPhoenix
//
//  Created by David Stump on 12/1/14.
//  Copyright (c) 2014 David Stump. All rights reserved.
//

import Foundation
import Starscream

public struct Phoenix {
  
  // MARK: Phoenix Message
  public class Message: Serializable {
    var subject: String?
    var body: AnyObject?
    public var message: AnyObject?
    
    public init(subject: String, body: AnyObject) {
      (self.subject, self.body) = (subject, body)
      super.init()
      create()
    }
    
    public init(message: AnyObject) {
      self.message = message
      super.init()
      create(false)
    }
    
    func create(single: Bool = true) -> [String: AnyObject] {
      if single {
        return [self.subject!: self.body!]
      } else {
        return self.message! as! [String: AnyObject]
      }
    }
  }
  
  // MARK: Phoenix Binding
  class Binding {
    var event: String
    var callback: AnyObject -> Void?
    
    init(event: String, callback: AnyObject -> Void?) {
      (self.event, self.callback) = (event, callback)
      create()
    }
    
    func create() -> (String, AnyObject -> Void?) {
      return (event, callback)
    }
  }
  
  // MARK: Phoenix Channel
  public class Channel {
    var bindings: [Phoenix.Binding] = []
    var topic: String?
    var callback: (AnyObject -> Void?)
    var socket: Phoenix.Socket?
    
    init(topic: String, callback: (AnyObject -> Void), socket: Phoenix.Socket) {
      (self.topic, self.callback, self.socket) = (topic, { callback($0) }, socket)
      reset()
    }
    
    func reset() {
      bindings = []
    }
    
    public func on(event: String, callback: (AnyObject -> Void)) {
      bindings.append(Phoenix.Binding(event: event, callback: { callback($0) }))
    }
    
    func isMember(topic  topic: String) -> Bool {
      return self.topic == topic
    }
    
    func off(event: String) {
      var newBindings: [Phoenix.Binding] = []
      for binding in bindings {
        if binding.event != event {
          newBindings.append(Phoenix.Binding(event: binding.event, callback: binding.callback))
        }
      }
      bindings = newBindings
    }
    
    func trigger(triggerEvent: String, msg: Phoenix.Message) {
      for binding in bindings {
        if binding.event == triggerEvent {
          binding.callback(msg)
        }
      }
    }
    
    func send(event: String, message: Phoenix.Message) {
      print("conn sending")
      let payload = Phoenix.Payload(topic: topic!, event: event, message: message)
      socket?.send(payload)
    }
    
    func leave(message: Phoenix.Message) {
      if let sock = socket {
        sock.leave(topic: topic!, message: message)
      }
      reset()
    }
  }
  
  // MARK: Phoenix Payload
  public class Payload {
    var topic: String
    var event: String
    var message: Phoenix.Message
    
    public init(topic: String, event: String, message: Phoenix.Message) {
      (self.topic, self.event, self.message) = (topic, event, message)
    }
    
  }
  
  // MARK: Phoenix Socket
  public class Socket: NSObject, WebSocketDelegate {
    var conn: WebSocket?
    var endPoint: String?
    var channels: [Phoenix.Channel] = []
    var sendBuffer: [Phoenix.Payload] = []
    var sendBufferTimer: NSTimer?
    let flushEverySec = 0.1
    var reconnectTimer: NSTimer?
    let reconnectAfterSec = 5
    var heartbeatTimer: NSTimer?
    let heartbeatAfterSec = 30
    var messageReference: UInt64 = UInt64.min // 0 (max: 18,446,744,073,709,551,615)
    var joinMessage: Phoenix.Message?

    public init(domainAndPort:String, path:String, transport:String, prot:String = "http") {
      self.endPoint = Path.endpointWithProtocol(prot, domainAndPort: domainAndPort, path: path, transport: transport)
      super.init()
      resetBufferTimer()
      reconnect()
    }
    
    func close(callback: () -> ()) {
      if let connection = self.conn {
        connection.delegate = nil
        connection.disconnect()
      }
      callback()
    }
    
    func reconnect() {
      close() {
        self.conn = WebSocket(url: NSURL(string: self.endPoint!)!)
        if let connection = self.conn {
          connection.delegate = self
          connection.connect()
        }
      }
    }
    
    func resetBufferTimer() {
      sendBufferTimer?.invalidate()
      sendBufferTimer = NSTimer.scheduledTimerWithTimeInterval(NSTimeInterval(flushEverySec), target: self, selector: Selector("flushSendBuffer"), userInfo: nil, repeats: true)
    }
    
    func onOpen() {
      reconnectTimer?.invalidate()
      heartbeatTimer?.invalidate()
      heartbeatTimer = NSTimer.scheduledTimerWithTimeInterval(NSTimeInterval(heartbeatAfterSec), target: self, selector: Selector("sendHeartbeat"), userInfo: nil, repeats: true)
      rejoinAll()
    }
    
    func onClose(event: String) {
      heartbeatTimer?.invalidate()
      reconnectTimer?.invalidate()
      reconnectTimer = NSTimer.scheduledTimerWithTimeInterval(NSTimeInterval(reconnectAfterSec), target: self, selector: Selector("reconnect"), userInfo: nil, repeats: true)
    }
    
    func onError(error: NSError) {
      print("Error: \(error)")
    }
    
    func isConnected() -> Bool {
      if let connection = self.conn {
        return connection.isConnected
      } else {
        return false
      }
      
    }
    
    func rejoinAll() {
      for chan in channels {
        rejoin(chan as Phoenix.Channel)
      }
    }
    
    func rejoin(chan: Phoenix.Channel) {
      chan.reset()
      if let topic = chan.topic, joinMessage = self.joinMessage {
          let payload = Phoenix.Payload(topic: topic, event: "phx_join", message: joinMessage)
          send(payload)
          chan.callback(chan)
      }
    }
    
    public func join(topic  topic: String, message: Phoenix.Message, callback: (AnyObject -> Void)) {
      let chan = Phoenix.Channel(topic: topic, callback: callback, socket: self)
      self.joinMessage = message
      channels.append(chan)
      if isConnected() {
        print("joining")
        rejoin(chan)
      }
    }
    
    func leave(topic  topic: String, message: Phoenix.Message) {
      let leavingMessage = Phoenix.Message(subject: "status", body: "leaving")
      let payload = Phoenix.Payload(topic: topic, event: "leave", message: leavingMessage)
      send(payload)
      var newChannels: [Phoenix.Channel] = []
      for chan in channels {
        let c = chan as Phoenix.Channel
        if !c.isMember(topic: topic) {
          newChannels.append(c)
        }
      }
      channels = newChannels
    }
    
    public func send(data: Phoenix.Payload) {
      if isConnected() {
        doSendBuffer(data)
      } else {
        sendBuffer.append(data)
      }
    }
    
    func flushSendBuffer() {
      if isConnected() && sendBuffer.count > 0 {
        for data in sendBuffer {
          doSendBuffer(data)
        }
        sendBuffer = []
        resetBufferTimer()
      }
    }
    
    func doSendBuffer(data: Phoenix.Payload) {
      if let connection = self.conn {
        let json = self.payloadToJson(data)
        print("json: \(json)")
        connection.writeString(json)
      }
    }
    
    func sendHeartbeat() {
      let heartbeatMessage = Phoenix.Message(subject: "status", body: "heartbeat")
      let payload = Phoenix.Payload(topic: "phoenix", event: "heartbeat", message: heartbeatMessage)
      send(payload)
    }
    
    func onMessage(payload: Phoenix.Payload) {
      let (topic, event, message) = (payload.topic, payload.event, payload.message)
      for chan in channels {
        if chan.isMember(topic: topic) {
          chan.trigger(event, msg: message)
        }
      }
    }
    
    // WebSocket Delegate Methods
    public func websocketDidReceiveMessage(socket: WebSocket, text: String) {
      print("socket message: \(text)")
      let json = JSON.parse(text as NSString as String as String)
      let (topic, event) = (
        unwrappedJsonString(json["topic"].asString),
        unwrappedJsonString(json["event"].asString)
      )
      let msg: [String: AnyObject] = json["payload"].asDictionary!
      
      let messagePayload = Phoenix.Payload(topic: topic, event: event, message: Phoenix.Message(message: msg))
      onMessage(messagePayload)
    }
    
    public func websocketDidReceiveData(socket: WebSocket, data: NSData) {
      print("got some data: \(data.length)")
    }
    
    public func websocketDidDisconnect(socket: WebSocket, error: NSError?) {
      print("socket closed: \(error?.localizedDescription)")
      onClose("reason: \(error?.localizedDescription)")
    }
    
    public func websocketDidConnect(socket: WebSocket) {
      print("socket opened")
      onOpen()
    }
    
    public func websocketDidWriteError(error: NSError?) {
      onError(error!)
    }
    
    func unwrappedJsonString(string: String?) -> String {
      if let stringVal = string {
        return stringVal
      } else {
        return ""
      }
    }
    
    func makeRef() -> UInt64 {
      let newRef = messageReference + 1
      messageReference = (newRef == UINT64_MAX) ? 0 : newRef
      return newRef
    }
    
    func payloadToJson(payload: Phoenix.Payload) -> String {
      let ref = makeRef()
      var json = "{\"topic\": \"\(payload.topic)\", \"event\": \"\(payload.event)\", \"ref\": \"\(ref)\", "
      if NSString(string: payload.message.toJsonString()).containsString("message") {
        let msg = JSON.parse(String(payload.message.toJsonString()))["message"]
        let jsonMessage = msg.toString(true)
        json += "\"payload\": \(jsonMessage)"
      } else {
        json += "\"payload\": \(payload.message.toJsonString())"
      }
      json += "}"
      
      return json
    }
  }
}
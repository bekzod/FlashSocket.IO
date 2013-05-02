package com.pnwrain.flashsocket
{
	import com.pnwrain.flashsocket.events.FlashSocketEvent;
	
	import flash.events.Event;
	import flash.events.EventDispatcher;
	import flash.events.HTTPStatusEvent;
	import flash.events.IOErrorEvent;
	import flash.events.TimerEvent;
	import flash.net.URLLoader;
	import flash.net.URLRequest;
	import flash.net.URLRequestMethod;
	import flash.system.Security;
	import flash.utils.Timer;
	
	import mx.utils.URLUtil;
	
	import net.gimite.websocket.*;
	

	public class FlashSocket extends EventDispatcher implements IWebSocketLogger
	{


		public static const STATUS_READY        = "STATUS_READY";
		public static const STATUS_CONNECTED    = "STATUS_CONNECTED";
		public static const STATUS_CONNECTING   = "STATUS_CONNECTING";
		public static const STATUS_DISCONNECTED = "STATUS_DISCONNECTED";

		public var status:String;

		private var debug:Boolean = false;
		private var webSocket:WebSocket;
		private var loader:URLLoader;	

		public var sessionID:String;
		
		private var domain:String;
		private var endPoint:String;
		private var protocol:String;
		private var headers:Array;
		private var isSecureConnection:Boolean;

		private var heartBeatTimer:Timer;
		private var connectionTimeoutTimer:Timer;
		
		private var ackId:int   = 0;
		private var acks:Object = {};
		
		public function FlashSocket( domain:String, headers:Array = null)
		{

			if(domain.indexOf('://')){
				var spliters:Array = domain.split('://',2);
				isSecureConnection = spliters[0]=="https"
				domain 			   = spliters[1]
			}
			
			if(domain.lastIndexOf('/')){
				var spliters:Array = domain.split('/',2);
				domain = spliters[0];
				endPoint = '/'+spliters[1];
			}
			
			this.domain  = domain;
			this.headers = headers;
			
			loader = new URLLoader();
			loader.addEventListener(Event.COMPLETE, onDiscover);
			loader.addEventListener(HTTPStatusEvent.HTTP_STATUS, onDiscoverError);
			loader.addEventListener(IOErrorEvent.IO_ERROR ,onDiscoverError);

			heartBeatTimer         = new Timer(0);
			connectionTimeoutTimer = new Timer(0);
			heartBeatTimer.addEventListener(TimerEvent.TIMER, onHeartBeat);
			connectionTimeoutTimer.addEventListener(TimerEvent.TIMER, onConnectionTimeout);

			status = STATUS_READY
		}



		public function connect():void{
			if(status != STATUS_READY)close();

			var httpProtocal:String = isSecureConnection?"https":"http";

			var req:URLRequest = new URLRequest();
			req.url            = httpProtocal+"://" + domain + "/socket.io/1/?time=" + new Date().time
			req.method         = URLRequestMethod.POST;
			req.requestHeaders = headers;
			
			loader.load(req);

			status = STATUS_CONNECTING;
		}


		public function close():void{
			if(status == STATUS_READY)return;
			
			heartBeatTimer.stop();
			connectionTimeoutTimer.stop();
			
			if(status == STATUS_CONNECTING)loader.close();

			if(webSocket){
				webSocket.removeEventListener(WebSocketEvent.MESSAGE, onData);
				webSocket.removeEventListener(WebSocketEvent.CLOSE, onClose);
				webSocket.removeEventListener(WebSocketEvent.ERROR, onIoError);
				webSocket.close();
				webSocket = null 			
			}

			status = STATUS_READY;
		}

		
		private function onDiscover(event:Event):void{
			if(status != STATUS_CONNECTING) return;

			var response:String = event.target.data;
			var respData:Array = response.split(":");

			sessionID                 = respData[0];
			var heartBeatTimeout:int  = int(respData[1]);
			var connectionTimeout:int = int(respData[2]);
			var protocols:Array       = respData[3].toString().split(",");
			
			heartBeatTimer.delay         = heartBeatTimeout*1000*.8
			connectionTimeoutTimer.delay = connectionTimeout*1000

			if(protocols.indexOf("websocket") == -1)throw("server does not support websocket");

			var webSocketProtocal:String = isSecureConnection?"wss":"ws"
			var socketURL:String = webSocketProtocal+"://" + domain + "/socket.io/1/websocket/" + sessionID;
			onHandshake(socketURL);
		}

		private function onHandshake(socketURL:String):void{
			if(status != STATUS_CONNECTING) return;

			loadDefaultPolicyFile(socketURL);
			webSocket = new WebSocket(23,socketURL,[],"",null,null,null,null,this);
			webSocket.addEventListener(WebSocketEvent.MESSAGE, onData);
			webSocket.addEventListener(WebSocketEvent.CLOSE, onClose);
			webSocket.addEventListener(WebSocketEvent.ERROR, onIoError);
			
			status = STATUS_CONNECTED;
		}
		
		private function onHeartBeat(event:TimerEvent):void{
			webSocket.send('2::');
		}

		private function onConnectionTimeout(event:TimerEvent):void{
			_onDisconnect()
		}
		
		private function onDiscoverError(event:Event):void{
			if (event is HTTPStatusEvent && (event as HTTPStatusEvent).status == 200)return;
			status = STATUS_DISCONNECTED;
			close();
			dispatchEvent(new FlashSocketEvent(FlashSocketEvent.CONNECT_ERROR,this));
		}
		
		private function onClose(event:Event):void{
			status = STATUS_DISCONNECTED;
			close();
			dispatchEvent(new FlashSocketEvent(FlashSocketEvent.CLOSE,this));
		}
		
		private function onIoError(event:Event):void{
			status = STATUS_DISCONNECTED;
			close();
			dispatchEvent(new FlashSocketEvent(FlashSocketEvent.CONNECT_ERROR,this));
		}

		
		public function error(message:String):void {
			trace("webSocketError: "  + message);
		}
		
		private function onData(e:WebSocketEvent):void{
			var msg:String = decodeURIComponent(e.message);
			if (msg)_onMessage(msg);
		}

		private function _onConnect():void{
			heartBeatTimer.start();
			connectionTimeoutTimer.start();

			status = STATUS_CONNECTED;
			dispatchEvent(new FlashSocketEvent(FlashSocketEvent.CONNECT,this));
		};


		private function _onDisconnect():void{
			status = STATUS_DISCONNECTED;
			close();			
			dispatchEvent(new FlashSocketEvent(FlashSocketEvent.DISCONNECT,this));
		};
		
		
		private function _onMessage(message:String):void{
			connectionTimeoutTimer.reset();
			connectionTimeoutTimer.start();
			//https://github.com/LearnBoost/socket.io-spec#Encoding
			/*	0		Disconnect
				1::	Connect
				2::	Heartbeat
				3:: Message
				4:: Json Message
				5:: Event
				6	Ack
				7	Error
				8	noop
			*/
			var dm:Object = deFrame(message);

			switch ( dm.type ){
				case '0':
					_onDisconnect();
					break;
				case '1':
					if(endPoint==null){
						_onConnect();
						webSocket.send('1::');
					}else{
						if(dm.msgEndpoint == endPoint){
							_onConnect();
						}else{
							webSocket.send('1::'+endPoint);
						}
					}
					break;
				case '2':
					webSocket.send( '2::' );
					break;
				case '3':
					dispatchEvent(new FlashSocketEvent(FlashSocketEvent.MESSAGE,this,dm.msg));
					break;
				case '4':
					dispatchEvent(new FlashSocketEvent(FlashSocketEvent.MESSAGE,this,dm.msg));
					break;
				case '5':
					var m:Object = JSON.parse(dm.msg);
					var msgId:String = dm.msgId;
					var callback:Function = null;
					
					if(msgId){
						var plusIndex:uint = msgId.lastIndexOf("+");
						var mid:uint=plusIndex==msgId.length?uint(msgId):uint(msgId.substr(0,plusIndex));
						callback = function(data:String=null):void{
							sendCallbackAck(data,mid);
						}
					}	

					dispatchEvent(new FlashSocketEvent(m.name,this, m.args,callback));
					break;
				case '6':
					var msg:String    = dm.msg;
					var parts:Array   = msg.split('+');
					var id:int        = int(parts[0]);					
					var func:Function = acks[id] as Function;
					
					if (func!=null) {
						var args:Array;
						if(parts.length>1){
							args = JSON.parse(parts[1]) as Array;
							if(args.length>func.length)args = args.slice(0,func.length)
						}
						func.apply(null,args);
						delete  this.acks[id];
					}
					break;
			}
			
		}
		
		private function sendCallbackAck(data:String=null,messageid:uint=1):void{
			webSocket.send('6:::'+messageid.toString()+'+['+data+']');
		}
		
		protected function deFrame(message:String):Object{
			//[message type] ':' [message id ('+')] ':' [message endpoint] (':' [message data]) 
			var data:Array = [4]
			
			var count:uint      = 0;
			var startIndex:uint = 0;
			var lastStart:uint  = 0;
			
			while((startIndex = message.indexOf(":",startIndex+1))>0&&count<3){
				data[count] = message.slice(lastStart,startIndex);
				lastStart=startIndex+1
				count++;
			}

			data[count] = message.slice(lastStart)
			return {type:data[0],msgId:data[1],msgEndpoint:data[2],msg:data[3]};
		}
		
		
		public function send(msg:Object, event:String = null,callback:Function = null):void{
			var messageId:String = "";
			if (null != callback) {
				messageId = ackId.toString() + '%2B';
				acks[this.ackId] = callback;
				ackId++;
			}
			
			if ( event == null ){
				if ( msg is String){
					webSocket.send('3:'+messageId+':'+endPoint+':' + msg as String);
				}else if ( msg is Object ){
					webSocket.send('4:'+messageId+':'+endPoint+':' + JSON.stringify(msg));
				}else{
					throw("Unsupported Message Type");
				}
			}else{
				webSocket.send('5:'+messageId+':'+endPoint+':'+ JSON.stringify({"name":event,"args":msg}))
			}
		}
		
		
		private function loadDefaultPolicyFile(wsUrl:String):void {
			var policyUrl:String = "xmlsocket://" + URLUtil.getServerName(wsUrl) + ":843";
			Security.loadPolicyFile(policyUrl);
		}


		public function log(message:String):void {
			if (debug) {
				trace("webSocketLog: " + message);
			}
		}
	}
}
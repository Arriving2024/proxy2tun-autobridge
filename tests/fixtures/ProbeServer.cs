// Offline protocol fixtures only. These servers do not forward traffic and their
// synthetic ServerHello is not a completed or authenticated TLS handshake.
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace P2TTests {
    public sealed class ProbeServer : IDisposable {
        private TcpListener listener;
        private Thread thread;
        private string mode;
        public int Port { get; private set; }
        public string Target { get; private set; }
        public string Error { get; private set; }

        public ProbeServer(string fixtureMode) {
            mode = fixtureMode;
            listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            Port = ((IPEndPoint)listener.LocalEndpoint).Port;
            thread = new Thread(Run);
            thread.IsBackground = true;
            thread.Start();
        }
        private static byte[] Read(Stream stream, int count) {
            byte[] result = new byte[count];
            int offset = 0;
            while (offset < count) {
                int length = stream.Read(result, offset, count - offset);
                if (length == 0) throw new EndOfStreamException();
                offset += length;
            }
            return result;
        }
        private static void Write(Stream stream, byte[] bytes) { stream.Write(bytes,0,bytes.Length); }
        private void Run() {
            try {
                using (TcpClient client = listener.AcceptTcpClient()) {
                    client.NoDelay = true;
                    client.ReceiveTimeout = 3000; client.SendTimeout = 3000;
                    using (NetworkStream stream = client.GetStream()) {
                        if (mode == "stall") { Thread.Sleep(2400); return; }
                        if (mode.StartsWith("socks")) {
                            byte[] greeting = Read(stream,3);
                            if (greeting[0] != 5 || greeting[1] != 1 || greeting[2] != 0) throw new Exception("Bad greeting");
                            if (mode == "socks-auth") { Write(stream,new byte[] {5,2}); return; }
                            Write(stream,new byte[] {5,0});
                            byte[] connect = Read(stream,10);
                            Target = String.Format("{0}.{1}.{2}.{3}:{4}",connect[4],connect[5],connect[6],connect[7],connect[8]*256+connect[9]);
                            if (mode == "socks-denied") { Write(stream,new byte[] {5,5,0,1,0,0,0,0,0,0}); return; }
                            Write(stream,new byte[] {5,0,0,1,127,0,0,1,0,0});
                        } else {
                            StringBuilder request = new StringBuilder();
                            while (request.Length < 8192 && !request.ToString().EndsWith("\r\n\r\n")) request.Append((char)Read(stream,1)[0]);
                            Target = request.ToString().Split(' ')[1];
                            if (mode == "http-auth") { Write(stream,Encoding.ASCII.GetBytes("HTTP/1.1 407 Proxy Authentication Required\r\n\r\n")); return; }
                            if (mode == "web200") { Write(stream,Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html>ordinary web server</html>")); return; }
                            Write(stream,Encoding.ASCII.GetBytes("HTTP/1.1 200 Connection established\r\n\r\n"));
                        }
                        byte[] record = Read(stream,5);
                        Read(stream,record[3]*256+record[4]);
                        byte[] hello = new byte[47];
                        hello[0]=22; hello[1]=3; hello[2]=3; hello[3]=0; hello[4]=42;
                        hello[5]=2; hello[6]=0; hello[7]=0; hello[8]=38;
                        hello[9]=3; hello[10]=3;
                        hello[43]=0; hello[44]=0; hello[45]=47; hello[46]=0;
                        if (mode == "http-bad-tls") hello[5]=1;
                        if (mode == "http-fragmented") {
                            for (int i=0; i<hello.Length; i++) { stream.WriteByte(hello[i]); if (i % 8 == 0) Thread.Sleep(1); }
                        } else Write(stream,hello);
                    }
                }
            } catch (Exception e) { Error=e.GetType().Name; }
        }
        public void Dispose() { listener.Stop(); if (thread.IsAlive) thread.Join(1000); }
    }
}

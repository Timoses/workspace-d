module workspaced.com.dcd;

import std.file : tempDir;

import std.path;
import std.json;
import std.conv;
import std.stdio;
import std.regex;
import std.string;
import std.random;
import std.process;
import std.datetime;
import std.algorithm;
import core.thread;

import painlessjson;

import workspaced.api;

version (OSX) version = haveUnixSockets;
version (linux) version = haveUnixSockets;
version (BSD) version = haveUnixSockets;
version (FreeBSD) version = haveUnixSockets;

@component("dcd") :
/// Load function for dcd. Call with `{"cmd": "load", "components": ["dcd"]}`
/// This will start dcd-server and load all import paths specified by previously loaded modules such as dub if autoStart is true. All dcd methods are used with `"cmd": "dcd"`
/// Note: This will block any incoming requests while loading.
@load void start(string dir, string clientPath = "dcd-client",
		string serverPath = "dcd-server", ushort port = 9166, bool autoStart = true)
{
	.cwd = dir;
	.serverPath = serverPath;
	.clientPath = clientPath;
	.port = port;
	installedVersion = execute([clientPath, "--version"]).output;
	version (haveUnixSockets)
		hasUnixDomainSockets = supportsUnixDomainSockets(installedVersion);
	if (autoStart)
		startServer();
}

enum verRegex = ctRegex!`(\d+)\.(\d+)\.\d+`;
bool supportsUnixDomainSockets(string ver)
{
	auto match = ver.matchFirst(verRegex);
	assert(match);
	int major = match[1].to!int;
	int minor = match[2].to!int;
	if (major > 0)
		return true;
	if (major == 0 && minor >= 8)
		return true;
	return false;
}

unittest
{
	assert(supportsUnixDomainSockets("0.8.0-beta2+9ec55f40a26f6bb3ca95dc9232a239df6ed25c37"));
	assert(!supportsUnixDomainSockets("0.7.9-beta3"));
	assert(!supportsUnixDomainSockets("0.7.0"));
	assert(supportsUnixDomainSockets("1.0.0"));
}

/// This stops the dcd-server instance safely and waits for it to exit
@unload void stop()
{
	stopServerSync();
	Thread.sleep(100.msecs);
	killServer();
}

/// This will start the dcd-server and load import paths from the current provider
/// Call_With: `{"subcmd": "setup-server"}`
@arguments("subcmd", "setup-server")
void setupServer(string[] additionalImports = [])
{
	startServer(importPathProvider() ~ additionalImports);
}

/// This will start the dcd-server
/// Call_With: `{"subcmd": "start-server"}`
@arguments("subcmd", "start-server")
void startServer(string[] additionalImports = [])
{
	if (isPortRunning(port))
		throw new Exception("Already running dcd on port " ~ port.to!string);
	string[] imports;
	foreach (i; additionalImports)
		imports ~= "-I" ~ i;
	.runningPort = port;
	.socketFile = buildPath(tempDir, "workspace-d-sock" ~ thisProcessID.to!string(36));
	serverPipes = raw([serverPath] ~ clientArgs ~ imports,
			Redirect.stdin | Redirect.stderr | Redirect.stdoutToStderr);
	while (!serverPipes.stderr.eof)
	{
		string line = serverPipes.stderr.readln();
		stderr.writeln("Server: ", line);
		stderr.flush();
		if (line.canFind(" Startup completed in "))
			break;
	}
	new Thread({
		while (!serverPipes.stderr.eof)
		{
			stderr.writeln("Server: ", serverPipes.stderr.readln());
		}
		stderr.writeln("DCD-Server stopped with code ", serverPipes.pid.wait());
	}).start();
}

void stopServerSync()
{
	while (!serverPipes.pid.tryWait().terminated)
		execClient(["--shutdown"]);
}

/// This stops the dcd-server asynchronously
/// Returns: null
/// Call_With: `{"subcmd": "stop-server"}`
@async @arguments("subcmd", "stop-server")
void stopServer(AsyncCallback cb)
{
	new Thread({ /**/
		try
		{
			stopServerSync();
			cb(null, JSONValue(null));
		}
		catch (Throwable t)
		{
			cb(t, JSONValue(null));
		}
	}).start();
}

/// This will kill the process associated with the dcd-server instance
/// Call_With: `{"subcmd": "kill-server"}`
@arguments("subcmd", "kill-server")
void killServer()
{
	if (!serverPipes.pid.tryWait().terminated)
		serverPipes.pid.kill();
}

/// This will stop the dcd-server safely and restart it again using setup-server asynchronously
/// Returns: null
/// Call_With: `{"subcmd": "restart-server"}`
@async @arguments("subcmd", "restart-server")
void restartServer(AsyncCallback cb)
{
	new Thread({ /**/
		try
		{
			stopServerSync();
			setupServer();
			cb(null, JSONValue(null));
		}
		catch (Throwable t)
		{
			cb(t, JSONValue(null));
		}
	}).start();
}

/// This will query the current dcd-server status
/// Returns: `{isRunning: bool}` If the dcd-server process is not running anymore it will return isRunning: false. Otherwise it will check for server status using `dcd-client --query`
/// Call_With: `{"subcmd": "status"}`
@arguments("subcmd", "status")
auto serverStatus() @property
{
	DCDServerStatus status;
	if (serverPipes.pid && serverPipes.pid.tryWait().terminated)
		status.isRunning = false;
	else if (hasUnixDomainSockets)
		status.isRunning = true;
	else
		status.isRunning = isPortRunning(runningPort);
	return status;
}

/// Searches for a symbol across all files using `dcd-client --search`
/// Returns: `[{file: string, position: int, type: string}]`
/// Call_With: `{"subcmd": "search-symbol"}`
@arguments("subcmd", "search-symbol")
@async auto searchSymbol(AsyncCallback cb, string query)
{
	new Thread({
		try
		{
			auto pipes = doClient(["--search", query]);
			scope (exit)
			{
				pipes.pid.wait();
				pipes.destroy();
			}
			pipes.stdin.close();
			DCDSearchResult[] results;
			while (pipes.stdout.isOpen && !pipes.stdout.eof)
			{
				string line = pipes.stdout.readln();
				if (line.length == 0)
					continue;
				string[] splits = line[0 .. $ - 1].split('\t');
				results ~= DCDSearchResult(splits[0], toImpl!(int)(splits[2]), splits[1]);
			}
			cb(null, results.toJSON);
		}
		catch (Throwable t)
		{
			cb(t, JSONValue(null));
		}
	}).start();
}

/// Reloads import paths from the current provider. Call reload there before calling it here.
/// Call_With: `{"subcmd": "refresh-imports"}`
@arguments("subcmd", "refresh-imports")
void refreshImports()
{
	addImports(importPathProvider());
}

/// Manually adds import paths as string array
/// Call_With: `{"subcmd": "add-imports"}`
@arguments("subcmd", "add-imports")
void addImports(string[] imports)
{
	knownImports ~= imports;
	updateImports();
}

/// Searches for an open port to spawn dcd-server in asynchronously starting with `port`, always increasing by one.
/// Returns: null if not available, otherwise the port as number
/// Call_With: `{"subcmd": "find-and-select-port"}`
@arguments("subcmd", "find-and-select-port")
@async void findAndSelectPort(AsyncCallback cb, ushort port = 9166)
{
	if (hasUnixDomainSockets)
	{
		cb(null, JSONValue(null));
		return;
	}
	new Thread({ /**/
		try
		{
			auto newPort = findOpen(port);
			.port = newPort;
			cb(null, .port.toJSON());
		}
		catch (Throwable t)
		{
			cb(t, JSONValue(null));
		}
	}).start();
}

/// Finds the declaration of the symbol at position `pos` in the code
/// Returns: `[0: file: string, 1: position: int]`
/// Call_With: `{"subcmd": "find-declaration"}`
@arguments("subcmd", "find-declaration")
@async void findDeclaration(AsyncCallback cb, string code, int pos)
{
	new Thread({
		try
		{
			auto pipes = doClient(["-c", pos.to!string, "--symbolLocation"]);
			scope (exit)
			{
				pipes.pid.wait();
				pipes.destroy();
			}
			pipes.stdin.write(code);
			pipes.stdin.close();
			string line = pipes.stdout.readln();
			if (line.length == 0)
			{
				cb(null, JSONValue(null));
				return;
			}
			string[] splits = line[0 .. $ - 1].split('\t');
			if (splits.length != 2)
			{
				cb(null, JSONValue(null));
				return;
			}
			cb(null, JSONValue([JSONValue(splits[0]), JSONValue(splits[1].to!int)]));
		}
		catch (Throwable t)
		{
			cb(t, JSONValue(null));
		}
	}).start();
}

/// Finds the documentation of the symbol at position `pos` in the code
/// Returns: `[string]`
/// Call_With: `{"subcmd": "get-documentation"}`
@arguments("subcmd", "get-documentation")
@async void getDocumentation(AsyncCallback cb, string code, int pos)
{
	new Thread({
		try
		{
			auto pipes = doClient(["--doc", "-c", pos.to!string]);
			scope (exit)
			{
				pipes.pid.wait();
				pipes.destroy();
			}
			pipes.stdin.write(code);
			pipes.stdin.close();
			string data;
			while (pipes.stdout.isOpen && !pipes.stdout.eof)
			{
				string line = pipes.stdout.readln();
				if (line.length)
					data ~= line[0 .. $ - 1];
			}
			cb(null, JSONValue(data.replace("\\n", "\n")));
		}
		catch (Throwable t)
		{
			cb(t, JSONValue(null));
		}
	}).start();
}

/// Returns the used socket file. Only available on OSX, linux and BSD with DCD >= 0.8.0
/// Throws an error if not available.
@arguments("subcmd", "get-socketfile")
string getSocketFile()
{
	if (!hasUnixDomainSockets)
		throw new Exception("Unix domain sockets not supported");
	return socketFile;
}

/// Returns the used running port. Throws an error if using unix sockets instead
@arguments("subcmd", "get-port")
ushort getRunningPort()
{
	if (hasUnixDomainSockets)
		throw new Exception("Using unix domain sockets instead of a port");
	return runningPort;
}

/// Queries for code completion at position `pos` in code
/// Returns: `{type:string}` where type is either identifiers, calltips or raw.
/// When identifiers: `{type:"identifiers", identifiers:[{identifier:string, type:string}]}`
/// When calltips: `{type:"calltips", calltips:[string]}`
/// When raw: `{type:"raw", raw:[string]}`
/// Raw is anything else than identifiers and calltips which might not be implemented by this point.
/// Call_With: `{"subcmd": "list-completion"}`
@arguments("subcmd", "list-completion")
@async void listCompletion(AsyncCallback cb, string code, int pos)
{
	new Thread({
		try
		{
			auto pipes = doClient(["-c", pos.to!string]);
			scope (exit)
			{
				pipes.pid.wait();
				pipes.destroy();
			}
			pipes.stdin.write(code);
			pipes.stdin.close();
			string[] data;
			while (pipes.stdout.isOpen && !pipes.stdout.eof)
			{
				string line = pipes.stdout.readln();
				if (line.length == 0)
					continue;
				data ~= line[0 .. $ - 1];
			}
			int[] emptyArr;
			if (data.length == 0)
			{
				cb(null, JSONValue(["type" : JSONValue("identifiers"),
					"identifiers" : emptyArr.toJSON()]));
				return;
			}
			if (data[0] == "calltips")
			{
				cb(null, JSONValue(["type" : JSONValue("calltips"), "calltips"
					: data[1 .. $].toJSON()]));
				return;
			}
			else if (data[0] == "identifiers")
			{
				DCDIdentifier[] identifiers;
				foreach (line; data[1 .. $])
				{
					string[] splits = line.split('\t');
					identifiers ~= DCDIdentifier(splits[0], splits[1]);
				}
				cb(null, JSONValue(["type" : JSONValue("identifiers"),
					"identifiers" : identifiers.toJSON()]));
				return;
			}
			else
			{
				cb(null, JSONValue(["type" : JSONValue("raw"), "raw" : data.toJSON()]));
				return;
			}
		}
		catch (Throwable e)
		{
			cb(e, JSONValue(null));
		}
	}).start();
}

void updateImports()
{
	string[] args;
	foreach (path; knownImports)
		args ~= "-I" ~ path;
	execClient(args);
}

private:

__gshared
{
	string clientPath, serverPath, cwd;
	string installedVersion;
	bool hasUnixDomainSockets = false;
	ProcessPipes serverPipes;
	ushort port, runningPort;
	string socketFile;
	string[] knownImports;
}

string[] clientArgs()
{
	if (hasUnixDomainSockets)
		return ["--socketFile", socketFile];
	else
		return ["--port", runningPort.to!string];
}

auto doClient(string[] args)
{
	return raw([clientPath] ~ clientArgs ~ args);
}

auto raw(string[] args, Redirect redirect = Redirect.all)
{
	return pipeProcess(args, redirect, null, Config.none, cwd);
}

auto execClient(string[] args)
{
	return rawExec([clientPath] ~ clientArgs ~ args);
}

auto rawExec(string[] args)
{
	return execute(args, null, Config.none, size_t.max, cwd);
}

bool isPortRunning(ushort port)
{
	if (hasUnixDomainSockets)
		return false;
	auto ret = execute([clientPath, "-q"] ~ clientArgs);
	return ret.status == 0;
}

ushort findOpen(ushort port)
{
	port--;
	bool isRunning;
	do
	{
		port++;
		isRunning = isPortRunning(port);
	}
	while (isRunning);
	return port;
}

private struct DCDServerStatus
{
	bool isRunning;
}

private struct DCDIdentifier
{
	string identifier;
	string type;
}

private struct DCDSearchResult
{
	string file;
	int position;
	string type;
}

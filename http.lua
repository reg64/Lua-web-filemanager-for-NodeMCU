-- Yichang 2022-11-02 https://github.com/yichang
-- helper
function urlDecode(url)
	return url:gsub('%%(%x%x)', function(x)
		return string.char(tonumber(x, 16))
	end)
end

-- Response
Res = {
	_skt = nil,
	_type = nil,
	_status = nil,
	_redirectUrl = nil,
}

function Res:new(skt)
	local o = {}
	setmetatable(o, self)
    self.__index = self
    o._skt = skt
    return o
end

function Res:redirect(url, status)
	status = status or 302
	self:status(status)
	self._redirectUrl = url
	self:send(status)
end

function Res:type(type)
	self._type = type
end

function Res:status(status)
	self._status = status
end

function Res:send(body)
	self._status = self._status or 200
	self._type = self._type or 'text/html'
	local buf = 'HTTP/1.1 ' .. self._status .. '\r\n'
		.. 'Content-Type: ' .. self._type .. '\r\n'
		.. 'Content-Length:' .. string.len(body) .. '\r\n'
	if self._redirectUrl ~= nil then
		buf = buf .. 'Location: ' .. self._redirectUrl .. '\r\n'
	end
	buf = buf .. '\r\n' .. body

	local function doSend()
		if buf == '' then 
			self:close()
		else
			self._skt:send(string.sub(buf, 1, 512))
			buf = string.sub(buf, 513)
		end
	end
	self._skt:on('sent', doSend)
	doSend()
end

function Res:sendFile(filename)
	if file.exists(filename .. '.gz') then
		filename = filename .. '.gz'
	elseif not file.exists(filename) then
		self:status(404)
		self:send(404)
		return
	end

	self._status = self._status or 200
	local header = 'HTTP/1.1 ' .. self._status .. '\r\n'
	self._type = self._type or 'text/html'
	header = header .. 'Content-Type: ' .. self._type .. '\r\n'
	if string.sub(filename, -3) == '.gz' then
		header = header .. 'Content-Encoding: gzip\r\n'
	end
	header = header .. '\r\n'

	print('* Sending ', filename)
	local pos = 0
	local function doSend()
		file.open(filename, 'r')
		if file.seek('set', pos) == nil then
			self:close()
			print('* Finished ', filename)
		else
			local buf = file.read(512)
			pos = pos + 512
			self._skt:send(buf)
		end
		file.close()
	end
	self._skt:on('sent', doSend)
	
	self._skt:send(header)
end

function Res:close()
	self._skt:on('sent', function() end) -- release closures context
	self._skt:on('receive', function() end)
	self._skt:close()
	self._skt = nil
end

-- Middleware
function parseHeader(req, res)
	local _, _, method, path, vars = string.find(req.source, '([A-Z]+) (.+)?(.*) HTTP')
	if method == nil then
		_, _, method, path = string.find(req.source, '([A-Z]+) (.+) HTTP')
	end
	local _GET = {}
	if (vars ~= nil and vars ~= '') then
		vars = urlDecode(vars)
		for k, v in string.gmatch(vars, '([^&]+)=([^&]*)&*') do
			_GET[k] = v
		end
	end
	req.method = method
	req.query = _GET
	req.path = path
	return true
end

function staticFile(req, res)
	local f = 'index.html'
	if req.path ~= '/' then
		f = string.gsub(string.sub(req.path, 2), '/', '_')
	end
	res:sendFile(f)
end

-- HttpServer
http = {
	_srv = nil,
	_mids = {{
		url = '.*',
		cb = parseHeader
	}, {
		url = '.*',
		cb = staticFile
	}}
}

function http:use(url, cb)
	table.insert(self._mids, #self._mids, {
		url = url,
		cb = cb
	})
end

function http:close()
	self._srv:close()
	self._srv = nil
end

function http:listen(port)
	self._srv = net.createServer(net.TCP)
	self._srv:listen(port, function(conn)
		conn:on('receive', function(skt, msg)
			-- upload file
			local _,pos,filename = string.find(msg, 'file[n]ame="([^"]+)"[^\r\n]*[\n\r]+[^\r\n]*[\r\n]+')
			local posend,_,over = string.find(msg, '(------WebKitFormBoundary)',string.len(msg)-48)

			if filename ~= nil then
				print("OPEN:"..filename)
				file.open(filename,'w+')
				isopen = 1
			end
			if isopen~=nil then
				if posend~=nil then msg=string.sub(msg,1,posend-1) end
				if pos~=nil then msg=string.sub(msg,pos+1) end
				file.write(msg) 
				if posend~=nil then 
					file.close()
					isopen = nil
					print("Close:"..over)
				end
			end
			--other apps
			local req = { source = msg, path = '', ip = skt:getpeer() }
			local res = Res:new(skt)
			for i = 1, #self._mids do
				if req.path and string.find(req.path, '^' .. self._mids[i].url .. '$')
					and not self._mids[i].cb(req, res) then
					break
				end
			end
			collectgarbage()
		end)
	end)
end

-- apps
http:use('/ls', function(req, res)
    l = file.list()
	s = "["
	for k,v in pairs(l) do
		s = s.."['"..k.."','"..v.."'],"
	  end
	res._type="json"
	res:send(s.."]")
	print(req.path)
end)

http:use('/ld', function(req, res)
    if req.query.name ~= nil then
		res._type="text/text"
        res:sendFile(req.query.name)
    end
	print(req.path)
end)

http:use('/upload', function(req, res)
    res:send("ok")
	print(req.path)
end)

http:use('/restart', function(req, res)
    res:send("ok")
	print(req.path)
	node.restart()
end)

http:listen(80)

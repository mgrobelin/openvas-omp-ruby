#
# = openvas-omp.rb: communicate with OpenVAS manager over OMP
#
# Author:: Vlatko Kosturjak
#
# (C) Vlatko Kosturjak, Kost. Distributed under MIT license:
# http://www.opensource.org/licenses/mit-license.php
# 
# == What is this library? 
# 
# This library is used for communication with OpenVAS manager over OMP
# You can start, stop, pause and resume scan. Watch progress and status of 
# scan, download report, etc.
#
# == Requirements
# 
# Required libraries are standard Ruby libraries: socket,timeout,openssl,
# rexml/document, rexml/text, base64
#
# == Usage:
# 
#  require 'openvas-omp'
#
#  ov=OpenVASOMP::OpenVASOMP.new("user"=>'openvas',"password"=>'openvas')
#  config=ov.config_get.index("Full and fast")
#  target=ov.target_create({"name"=>"t", "hosts"=>"127.0.0.1", "comment"=>"t"})
#  taskid=ov.task_create({"name"=>"t","comment"=>"t", "target"=>target, "config"=>config})
#  ov.task_start(taskid)
#  while not ov.task_finished(taskid) do
#         stat=ov.task_get_byid(taskid)
#         puts "Status: #{stat['status']}, Progress: #{stat['progress']} %"
#         sleep 10
#  end
#  stat=ov.task_get_byid(taskid)
#  content=ov.report_get_byid(stat["lastreport"],'HTML')
#  File.open('report.html', 'w') {|f| f.write(content) }
#
#
# Modified for version 4 per http://www.openvas.org/protocol-doc.html
#

require 'socket'
require 'timeout'
require 'openssl'
require 'rexml/document'
require 'rexml/text'
require 'base64'

# OpenVASOMP module
# 
# Usage:
# 
#  require 'openvas-omp'
# 
#  ov=OpenVASOMP::OpenVASOMP.new("user"=>'openvas',"password"=>'openvas')

module OpenVASOMP

  class OMPError < :: RuntimeError
    attr_accessor :req, :reason

    def initialize(req, reason = '')
      self.req = req
      self.reason = reason
    end

    def to_s
      "OpenVAS OMP: #{self.reason}"
    end
  end

  class OMPResponseError < OMPError
    def initialize(reason=nil)
      self.reason = (reason.nil?) ? 'Error in OMP request/response' : reason
    end
  end

  class OMPAuthError < OMPError
    def initialize(reason=nil)
      self.reason = (reason.nil?) ? 'Authentication failed' : reason
    end
  end

  class XMLParsingError < OMPError
    def initialize(reason=nil)
      self.reason = (reason.nil?) ? 'XML parsing failed' : reason
    end
  end

  # Core class for OMP communication protocol
  class OpenVASOMP
    # initialize object: try to connect to OpenVAS using URL, user and password
    #
    # Usage:
    #
    #  ov=OpenVASOMP.new(user=>'user',password=>'pass')
    #  # default: host=>'localhost', port=>'9390'
    #
    def initialize(p={})


      @host = 'localhost'
      @port = 9390
      @user = 'openvas'
      @password = 'openvas'
      @bufsize = 16384
      @debug = 0

      @host=p[:host] if p.has_key?(:host)
      @port=p[:port] if p.has_key?(:port)
      @user=p[:user] if p.has_key?(:user)
      @password=p[:password] if p.has_key?(:password)
      @bufsize=p[:bufsize] if p.has_key?(:bufsize)
      @debug=p[:debug] if p.has_key?(:debug)

      puts "Host: #{@host}\nPort: #{@port}\nUser: #{@user}" if @debug>3
      puts 'Password: '+@password if @debug>99

      @areq=''
      @read_timeout=3
      if defined? p[:noautoconnect] and not p[:noautoconnect]
        connect
        if defined? p[:noautologin] and not p[:noautologin]
          login
        end
      end
    end

    # Sets debug level
    #
    # Usage:
    #
    # ov.debug(3)
    #
    def debug (level)
      @debug=level
    end

    # Low level method - Connect to SSL socket
    #
    # Usage:
    #
    # ov.connect
    #
    def connect
      @plain_socket=TCPSocket.open(@host, @port)
      ssl_context = OpenSSL::SSL::SSLContext.new
      @socket = OpenSSL::SSL::SSLSocket.new(@plain_socket, ssl_context)
      @socket.sync_close = true
      @socket.connect
    end

    # Low level method - Disconnect SSL socket
    #
    # Usage:
    #
    # ov.disconnect
    #
    def disconnect
      @socket.close if @socket
    end

    # Low level method: Send request and receive response - socket
    #
    # Usage:
    #
    # ov.connect;
    # puts ov.sendrecv("<get_version/>")
    # ov.disconnect;
    #
    def sendrecv (tosend)
      unless @socket
        connect
      end

      puts "SENDING: #{tosend}" if @debug>3
      @socket.puts(tosend)

      @rbuf=''
      size=0
      begin
        begin
          timeout(@read_timeout) {
            a = @socket.sysread(@bufsize)
            size=a.length
            # puts "sysread #{size} bytes"
            @rbuf << a
          }
        rescue Timeout::Error
          size=0
        rescue EOFError => e
          raise OMPResponseError e
        end
      end while size>=@bufsize
      response=@rbuf

      puts "RECEIVED: #{response}" if @debug>3
      response
    end

    # get OMP version (you don't need to be authenticated)
    #
    # Usage:
    #
    # ov.version_get
    #
    def version_get
      vreq='<get_version/>'
      resp=sendrecv(vreq)
      resp = '<X>'+resp+'</X>'
      begin
        docxml = REXML::Document.new(resp)
        docxml.root.elements['get_version_response'].elements['version'].text
      rescue
        raise XMLParsingError
      end
    end

    # produce single XML element with attributes specified as hash
    # low-level function
    #
    # Usage:
    #
    # ov.xml_attr
    #
    def xml_attr(name, opts={})
      xml = REXML::Element.new(name)
      opts.keys.each do |k|
        xml.attributes[k] = opts[k]
      end
      xml
    end

    # produce multiple XML elements with text specified as hash
    # low-level function
    #
    # Usage:
    #
    # ov.xml_ele
    #
    def xml_ele(name, child={})
      xml = REXML::Element.new(name)
      child.keys.each do |k|
        xml.add_element(k)
        xml.elements[k].text = child[k]
      end
      xml
    end

    # produce multiple XML elements with text specified as hash
    # also produce multiple XML elements with attributes
    # low-level function
    #
    # Usage:
    #
    # ov.xml_mix
    #
    def xml_mix(name, child, attr, elem)
      xml = REXML::Element.new(name)
      child.keys.each do |k|
        xml.add_element(k)
        xml.elements[k].text = child[k]
      end
      elem.keys.each do |k|
        xml.add_element(k)
        xml.elements[k].attributes[attr] = elem[k]
      end
      xml
    end

    # login to OpenVAS server.
    # if successful returns authentication XML for further usage
    # if unsuccessful returns empty string
    #
    # Usage:
    #
    # ov.login
    #
    def login
      areq='<authenticate>'+xml_ele('credentials', {'username' => @user, 'password' => @password}).to_s+'</authenticate>'
      resp=sendrecv("#{areq}<HELP/>")
      # wrap it inside tags, so rexml does not complain
      resp = "<X>#{resp}</X>"

      begin
        docxml = REXML::Document.new(resp)
        status=docxml.root.elements['authenticate_response'].attributes['status'].to_i
      rescue
        raise XMLParsingError
      end
      if status == 200
        @areq=areq
      else
        raise OMPAuthError
      end
    end

    # check if we're successful logged in
    # if successful returns true
    # if unsuccessful returns false
    #
    # Usage:
    #
    # if ov.logged_in then
    # 	puts "logged in"
    # end
    #
    def logged_in
      (@areq == '') ? false : true
    end

    # logout from OpenVAS server.
    # it actually just sets internal authentication XML to empty str
    # (as in OMP you have to send username/password each time)
    # (i.e. there is no session id)
    #
    # Usage:
    #
    # ov.logout
    #
    def logout
      disconnect
      @areq = ''
      nil
    end

    # OMP low level method - Send string request wrapped with
    # authentication XML and return response as string
    #
    # Usage:
    #
    # ov.request_xml("<HELP/")
    #
    def omp_request_raw (request)
      sendrecv(@areq+request)
    end

    # OMP low level method - Send string request wrapped with
    # authentication XML and return REXML parsed object
    #
    # Usage:
    #
    # rexmlobject = ov.request_xml("<HELP/")
    #
    def omp_request_xml (request)
      resp = sendrecv(@areq+request)
      resp = "<X>#{resp}</X>"

      begin
        docxml = REXML::Document.new(resp)
        status=docxml.root.elements['authenticate_response'].attributes['status'].to_i
        if status<200 and status>299
          raise OMPAuthError
        end
        docxml.root
      rescue
        raise XMLParsingError "Request: #{request}\nResponse:\n#{resp}"
      end
    end

    # OMP - Create target for scanning
    #
    # Usage:
    #
    # target_id = ov.target_create("name"=>"localhost",
    # 	"hosts"=>"127.0.0.1","comment"=>"yes")
    #
    def target_create (p={})
      xmlreq = xml_ele('create_target', p).to_s

      begin
        omp_request_xml(xmlreq).elements['create_target_response'].attributes['id']
     rescue
        raise OMPResponseError
      end
    end

    # OMP - Delete target
    #
    # Usage:
    #
    # ov.target_delete(target_id)
    #
    def target_delete (id)
      xmlreq=xml_attr('delete_target', {'target_id' => id}).to_s
      begin
        omp_request_xml(xmlreq)
      rescue
        raise OMPResponseError
      end
    end

    # OMP - Get target for scanning and returns rexml object
    #
    # Usage:
    # rexmlobject = target_get_raw("target_id"=>target_id)
    #
    def target_get_raw (p={})
      xmlreq=xml_attr('get_targets', p).to_s

      begin
        omp_request_xml(xmlreq)
      rescue
        raise OMPResponseError
      end
    end

    # OMP - Get all targets for scanning and returns array of hashes
    # with following keys: id,name,comment,hosts,max_hosts,in_use
    #
    # Usage:
    # array_of_hashes = target_get_all
    #
    def target_get_all (p={})
      begin
        xr=target_get_raw(p)
        list=Array.new
        xr.elements.each('//get_targets_response/target') do |target|
          td=Hash.new
          td['id']=target.attributes['id']
          td['name']=target.elements['name'].text
          td['comment']=target.elements['comment'].text
          td['hosts']=target.elements['hosts'].text
          td['max_hosts']=target.elements['max_hosts'].text
          td['in_use']=target.elements['in_use'].text
          list.push td
        end
        list
      rescue
        raise OMPResponseError
      end
    end

    def target_get_byid (id)
      begin
        xr=target_get_raw('target_id' => id)
        xr.elements.each('//get_targets_response/target') do |target|
          td=Hash.new
          td['id']=target.attributes['id']
          td['name']=target.elements['name'].text
          td['comment']=target.elements['comment'].text
          td['hosts']=target.elements['hosts'].text
          td['max_hosts']=target.elements['max_hosts'].text
          td['in_use']=target.elements['in_use'].text
          return td
        end
      rescue
        raise OMPResponseError
      end
    end

    # OMP - get reports and returns raw rexml object as response
    #
    # Usage:
    #
    # rexmlobject=ov.report_get_raw("format"=>"PDF")
    #
    # rexmlobject=ov.report_get_raw(
    #	"report_id" => "",
    #	"format"=>"PDF")
    #
    def report_get_raw (p={})
      xmlreq=xml_attr("get_reports", p).to_s
      begin
        omp_request_xml(xmlreq)
      rescue
        raise OMPResponseError
      end
    end

    # OMP - get report by id and format, returns report
    # (already base64 decoded if needed)
    #
    # format can be: HTML, NBE, PDF, ...
    #
    # Usage:
    #
    # pdf_content=ov.report_get_byid(id,"PDF")
    # File.open('report.pdf', 'w') {|f| f.write(pdf_content) }
    #
    def report_get_byid (id, format)
      format_id = format_get_by_name(format)
      decode=Array['HTML', 'NBE', 'PDF', 'ARF', 'TXT', 'LaTeX']
      xr=report_get_raw('report_id' => id, 'format_id' => format_id)

      if decode.include?(format)
        resp=xr.elements['//get_reports_response/report'].text
      else
        # puts xr
        resp=xr.elements['//get_reports_response/report'].to_s
        # puts resp
      end

      if decode.include?(format)
        resp=Base64.decode64(resp)
      end
      resp
    end

    # OMP - get report all, returns report
    #
    # Usage:
    #
    # pdf_content=ov.report_get_all
    #
    def report_get_all
      format_id = format_get_by_name('XML')
      begin
        xr=report_get_raw('format_id' => format_id)
      rescue
        raise OMPResponseError
      end

      list=Array.new
      xr.elements.each('//get_reports_response/report') do |target|
        # puts target
        td=Hash.new
        td['id']=target.attributes['id']
         # td["name"]=target.elements["name"].text
        # td["comment"]=target.elements["comment"].text
        # td["hosts"]=target.elements["hosts"].text
        # td["max_hosts"]=target.elements["max_hosts"].text
        # td["in_use"]=target.elements["in_use"].text
        list.push td
      end
      list
    end

    # OMP - get reports and returns raw rexml object as response
    #
    # Usage:
    #
    # rexmlobject=ov.result_get_raw("notes"=>0)
    #
    def result_get_raw (p={})
      begin
        xmlreq=xml_attr('get_results', p).to_s
        omp_request_xml(xmlreq)
      rescue
        raise OMPResponseError
      end
    end

    # OMP - get configs and returns rexml object as response
    #
    # Usage:
    #
    # rexmldocument=ov.config_get_raw
    #
    def config_get_raw (p={})
      xmlreq=xml_attr('get_configs', p).to_s
      begin
        omp_request_xml(xmlreq)
      rescue
        raise OMPResponseError
      end
    end

    # OMP - get configs and returns hash as response
    # hash[config_id]=config_name
    #
    # Usage:
    #
    # array_of_hashes=ov.config_get_all
    #
    def config_get_all (p={})
      begin
        xr=config_get_raw(p)
        tc=Array.new
        xr.elements.each('//get_configs_response/config') do |config|
          c=Hash.new
          c['id']=config.attributes['id']
          c['name']=config.elements['name'].text
          c['comment']=config.elements['comment'].text
          tc.push c
        end
        return tc
      rescue
        raise OMPResponseError
      end
    end

    # OMP - get configs and returns hash as response
    # hash[config_id]=config_name
    #
    # Usage:
    #
    # all_configs_hash=ov.config.get
    #
    # config_id=ov.config_get.index("Full and fast")
    #
    def config_get (p={})
      begin
        xr=config_get_raw(p)
        list=Hash.new
        xr.elements.each('//get_configs_response/config') do |config|
          id=config.attributes["id"]
          name=config.elements["name"].text
          list[id]=name
        end
        list
      rescue
        raise OMPResponseError
      end
    end

    # OMP - copy config with new name and returns new id
    #
    # Usage:
    #
    # new_config_id=config_copy(config_id,"new_name");
    #
    def config_copy (config_id, name)
      xmlreq=xml_attr('create_config',
                      {'copy' => config_id, 'name' => name}).to_s
      begin
        xr=omp_request_xml(xmlreq)
        id=xr.elements['create_config_response'].attributes['id']
        return id
      rescue
        raise OMPResponseError
      end
    end

    # OMP - create config with specified RC file and returns new id
    # name = name of new config
    # rcfile = base64 encoded OpenVAS rcfile
    #
    # Usage:
    #
    # config_id=config_create("name",rcfile);
    #
    def config_create (name, rcfile)
      xmlreq=xml_attr('create_config',
                      {'name' => name, 'rcfile' => rcfile}).to_s
      begin
        xr=omp_request_xml(xmlreq)
        id=xr.elements['create_config_response'].attributes['id']
      rescue
        raise OMPResponseError
      end
      id
    end


    # OMP - get formats and returns raw rexml object as response
    # Added for version 4
    #
    # Usage:
    #
    # rexmlobject=ov.format_get_raw
    #
    #
    def format_get_raw (p={})
      xmlreq=xml_attr('get_report_formats', p).to_s
      begin
        xr=omp_request_xml(xmlreq)
      rescue
        raise OMPResponseError
      end
      xr
    end


    # OMP - get report all, returns formats
    # added for version 4
    #
    # Usage:
    #
    # pdf_content=ov.format_get_all
    #
    def format_get_all
      begin
        xr=format_get_raw
        list=Array.new
        xr.elements.each('//get_report_formats_response/report_format') do |target|
          td=Hash.new
          td['id']=target.attributes['id']
          td['name']=target.elements['name'].text
          td['extension']=target.elements['extension'].text
          td['content_type']=target.elements['content_type'].text
          td['summary']=target.elements['summary'].text
          list.push td
        end
        list
      rescue
        raise OMPResponseError
      end
    end


    # OMP - get report all, returns formats
    # added for version 4
    #
    # Usage:
    #
    # pdf_content=ov.format_get_all
    #
    def format_get_by_name (name)
      begin
        x = format_get_all
        x.each { |f|
          return f['id'] if f['name'] == name
        }
        nil
      rescue
        raise OMPResponseError
      end
    end


    # OMP - creates task and returns id of created task
    #
    # Parameters which usually fit in p hash and i hash:
    # p = name,comment,rcfile
    # i = config,target,escalator,schedule
    #
    # Usage:
    #
    # task_id=ov.task_create_raw
    #
    def task_create_raw (p={}, i={})
      xmlreq=xml_mix('create_task', p, 'id', i).to_s
      begin
        xr=omp_request_xml(xmlreq)
        id=xr.elements['create_task_response'].attributes['id']
        return id
      rescue
        raise OMPResponseError
      end
    end

    # OMP - creates task and returns id of created task
    #
    # parameters = name,comment,rcfile,config,target,escalator,
    #		schedule
    #
    # Usage:
    #
    # config_id=o.config_get.index("Full and fast")
    # target_id=o.target_create(
    # {"name"=>"localtarget", "hosts"=>"127.0.0.1", "comment"=>"t"})
    # task_id=ov.task_create(
    # {"name"=>"testlocal","comment"=>"test", "target"=>target_id,
    # "config"=>config_id}
    #
    def task_create (p={})
      specials=Array['config', "target", "escalator", "schedule"]
      ids = Hash.new
      specials.each do |spec|
        if p.has_key?(spec)
          ids[spec]=p[spec]
          p.delete(spec)
        end
      end
      task_create_raw(p, ids)
    end

    # OMP - deletes task specified by task_id
    #
    # Usage:
    #
    # ov.task_delete(task_id)
    #
    def task_delete (task_id)
      xmlreq=xml_attr('delete_task', {'task_id' => task_id}).to_s
      begin
        omp_request_xml(xmlreq)
      rescue
        raise OMPResponseError
      end
    end

    # OMP - get task and returns raw rexml object as response
    #
    # Usage:
    #
    # rexmlobject=ov.task_get_raw("details"=>"0")
    #
    def task_get_raw (p={})
      xmlreq=xml_attr('get_tasks', p).to_s
      begin
        omp_request_xml(xmlreq)
      rescue
        raise OMPResponseError
      end
    end

    # OMP - get all tasks and returns array with hashes with
    # following content:
    # id,name,comment,status,progress,first_report,last_report
    #
    # Usage:
    #
    # array_of_hashes=ov.task_get_all
    #
    def task_get_all (p={})
      xr=task_get_raw(p)
      t=Array.new
      xr.elements.each('//get_tasks_response/task') do |task|
        td=Hash.new
        td['id']=task.attributes['id']
        td['name']=task.elements['name'].text
        td['comment']=task.elements['comment'].text
        td['status']=task.elements['status'].text
        td['progress']=task.elements['progress'].text
        if defined? task.elements['first_report'].elements['report'].attributes['id']
          td['firstreport']=task.elements['first_report'].elements['report'].attributes['id']
        else
          td['firstreport']=nil
        end
        if defined? task.elements['last_report'].elements["report"].attributes['id']
          td['lastreport']=task.elements["last_report"].elements["report"].attributes['id']
        else
          td['lastreport']=nil
        end
        t.push td
      end
      t
    end

    # OMP - get task specified by task_id and returns hash with
    # following content:
    # id,name,comment,status,progress,first_report,last_report
    #
    # Usage:
    #
    # hash=ov.task_get_byid(task_id)
    #
    def task_get_byid (id)
      xr=task_get_raw('task_id' => id, 'details' => 0)
      xr.elements.each('//get_tasks_response/task') do |task|
        td=Hash.new
        td['id']=task.attributes['id']
        td['name']=task.elements['name'].text
        td['comment']=task.elements['comment'].text
        td['status']=task.elements['status'].text
        td['progress']=task.elements['progress'].text

        if defined? task.elements['first_report'].elements['report'].attributes['id']
          td['firstreport']=task.elements['first_report'].elements['report'].attributes['id']
        else
          td['firstreport']=nil
        end

        if defined? task.elements['last_report'].elements['report'].attributes['id']
          td['lastreport']=task.elements['last_report'].elements['report'].attributes['id']
        else
          td['lastreport']=nil
        end
        return (td)
      end
    end

    # OMP - check if task specified by task_id is finished
    # (it checks if task status is "Done" in OMP)
    #
    # Usage:
    #
    # if ov.task_finished(task_id)
    #	puts "Task finished"
    # end
    #
    def task_finished (id)
      xr=task_get_raw('task_id' => id, 'details' => 0)
      xr.elements.each('//get_tasks_response/task') do |task|
        return (task.elements['status'].text == 'Done') ? true : false
      end
    end

    # OMP - check progress of task specified by task_id
    # (OMP returns -1 if task is finished, not started, etc)
    #
    # Usage:
    #
    # print "Progress: "
    # puts ov.task_progress(task_id)
    #
    def task_progress (id)
      xr=task_get_raw('task_id' => id, 'details' => 0)
      xr.elements.each('//get_tasks_response/task') do |task|
        return task.elements['progress'].text.to_i
      end
    end

    # OMP - starts task specified by task_id
    #
    # Usage:
    #
    # ov.task_start(task_id)
    #
    def task_start (task_id)
      xmlreq=xml_attr('start_task', {'task_id' => task_id}).to_s
      begin
        omp_request_xml(xmlreq)
      rescue
        raise OMPResponseError
      end
     end

    # OMP - stops task specified by task_id
    #
    # Usage:
    #
    # ov.task_stop(task_id)
    #
    def task_stop (task_id)
      xmlreq=xml_attr('stop_task', {'task_id' => task_id}).to_s
      begin
        omp_request_xml(xmlreq)
      rescue
        raise OMPResponseError
      end
    end

    # OMP - pauses task specified by task_id
    #
    # Usage:
    #
    # ov.task_pause(task_id)
    #
    def task_pause (task_id)
      xmlreq=xml_attr('pause_task', {'task_id' => task_id}).to_s
      begin
        omp_request_xml(xmlreq)
      rescue
        raise OMPResponseError
      end
    end

    # OMP - resumes (or starts) task specified by task_id
    #
    # Usage:
    #
    # ov.task_resume_or_start(task_id)
    #
    def task_resume_or_start (task_id)
      xmlreq=xml_attr('resume_or_start_task', {'task_id' => task_id}).to_s
      begin
        omp_request_xml(xmlreq)
      rescue
        raise OMPResponseError
      end
    end

  end # end of Class

end # of Module


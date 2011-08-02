require 'rubygems'
require 'isbn/tools'
require 'sinatra'
require 'sasquatch'
require 'rdf/json'
require 'rdf/ntriples'
require 'rdf/rdfxml'
require 'haml'
require 'rack/conneg'
require 'cgi'

use(Rack::Conneg) { |conneg|
  Rack::Mime::MIME_TYPES['.nt'] = 'text/plain'   
  conneg.set :accept_all_extensions, false
  conneg.set :fallback, :json
  conneg.ignore('/public/')
  conneg.ignore('/stylesheets/')
  conneg.provide([:rdf, :nt, :xml, :json])
}

module RDF
  class BIBO < RDF::Vocabulary("http://purl.org/ontology/bibo/");end
end

configure do
  set :store, Sasquatch::Store.new('openlibrary')
end

before do  
  if negotiated?
    content_type negotiated_type
  end
end

get '/' do
  response['Content-Type'] = "text/html"
  haml :index
end

get '/:identifier_type/:identifier' do
  headers['Cache-Control'] = 'public, max-age=43200'  
  query = case params[:identifier_type]
  when "isbn"
    unless isbn = normalize_isbn(params[:identifier])
      halt 400, {'Content-Type' => 'text/plain'}, 'Invalid ISBN sent!'
    end
    build_id_query(isbn, "bibo:isbn13")
  when "lccn"
    build_id_query(normalize_lccn(params[:identifier]), "bibo:lccn")
  when "oclc"
    build_id_query(params[:identifier], "bibo:oclcnum")
  when "books"
    build_edition_query("http://openlibrary.org/#{params[:identifier_type]}/#{params[:identifier]}")
  when "works"
    build_work_query("http://openlibrary.org/#{params[:identifier_type]}/#{params[:identifier]}")
  end

  response = options.store.sparql_describe(query)
  unless options.store.last_response.code == 200
    halt options.store.last_response.code, {'Content-Type' => 'text/plain'}, store.last_response.body
  end  
  if response.empty?
    if options.store.last_response.code == 200
      halt 404, {"Content-Type" => 'text/plain'}, "Resource not found"
    else
      halt 500, {"Content-Type" => 'text/plain'}, options.store.last_response.body.content
    end
  end
  resource = RDF::URI.intern(base_url+"/#{params[:identifier_type]}/#{params[:identifier]}")
  matches = case params[:identifier_type]
  when "isbn"
    response.query(:predicate=>RDF::BIBO.isbn13, :object=>normalize_isbn(params[:identifier])).each_subject
  when "lccn"
    response.query(:predicate=>RDF::BIBO.lccn, :object=>normalize_lccn(params[:identifier])).each_subject
  when "oclc"
    response.query(:predicate=>RDF::BIBO.oclcnum, :object=>params[:identifier]).each_subject
  else
    ["http://openlibrary.org/#{params[:identifier_type]}/#{params[:identifier]}"]
  end
  matches.each do |match|
    response << [resource, RDF::OWL.sameAs, match]
  end

  respond_to do | wants |
    wants.rdf { to_rdfxml(response) }
    wants.json { response.to_json }
    wants.nt { response.to_ntriples }
    wants.xml { to_rdfxml(response) }
  end
end

helpers do
  
  def normalize_lccn(lccn)
    lccn.gsub(/\s/,'')
  end  
  
  def normalize_isbn(isbn)
    id = ISBN_Tools.cleanup(isbn)
    case
    when ISBN_Tools.is_valid_isbn13?(id) then id
    when ISBN_Tools.is_valid_isbn10?(id) then ISBN_Tools.isbn10_to_isbn13(id)    
    end 
  end
  
  def base_url
    @base_url ||= "#{request.env['rack.url_scheme']}://#{request.env['HTTP_HOST']}"
  end
  
  def build_id_query(ids, predicate)
    id_clauses = []
    [*ids].each do |id|
      next unless id
      id_clauses << "?s #{predicate} \"#{id}\""
    end
    sparql =<<END
PREFIX bibo: <http://purl.org/ontology/bibo/>
PREFIX dct: <http://purl.org/dc/terms/>
DESCRIBE ?w ?m
WHERE {
{#{id_clauses.join("} UNION {")}} 
OPTIONAL {
  ?s dct:isVersionOf ?w.
}
OPTIONAL {
  ?w dct:hasVersion ?m .   
}
}    
END
   sparql
  end  
  
  def build_edition_query(uri)
    sparql =<<END
PREFIX bibo: <http://purl.org/ontology/bibo/>
PREFIX dct: <http://purl.org/dc/terms/>
DESCRIBE ?w ?m
WHERE {
<#{uri}> dct:isVersionOf ?w.
?w dct:hasVersion ?m .   
}    
END
   sparql    
 end
 def build_work_query(uri)
   sparql =<<END
PREFIX bibo: <http://purl.org/ontology/bibo/>
PREFIX dct: <http://purl.org/dc/terms/>
DESCRIBE <#{uri}> ?m
WHERE {
<#{uri}> dct:hasVersion ?m .   
}    
END
  sparql    
  end  
  
  def to_rdfxml(data)
    RDF::RDFXML::Writer.buffer do |writer|
      data.each_statement do |statement|
        writer << statement
      end      
    end
  end
end
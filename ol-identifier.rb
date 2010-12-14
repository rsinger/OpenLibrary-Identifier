require 'rubygems'
require 'isbn/tools'
require 'sinatra'
require 'rdf_objects/pho'
require 'json'
require 'rack/conneg'
require 'cgi'

use(Rack::Conneg) { |conneg|
  Rack::Mime::MIME_TYPES['.nt'] = 'text/plain'   
  conneg.set :accept_all_extensions, false
  conneg.set :fallback, :rdf
  conneg.ignore('/public/')
  conneg.ignore('/stylesheets/')
  conneg.provide([:rdf, :nt, :xml, :json])
}

configure do
  set :store, RDFObject::Store.new('http://api.talis.com/stores/openlibrary')
  Curie.add_prefixes! :bibo=>"http://purl.org/ontology/bibo/", :owl=>"http://www.w3.org/2002/07/owl#"
end

before do  
  content_type negotiated_type
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
  response = options.store.sparql_describe(query, "application/json")
  unless response.code == 200
    halt response.code, {'Content-Type' => 'text/plain'}, response.body
  end  
  if response.collection
    collection = RDFObject::Collection.new
    response.collection.values.each do |r|
      next if r.empty_graph?
      collection[r.uri] = r
    end
  else
    halt 500, {"Content-Type" => 'text/plain'}, response.body.content
  end
  resource = RDFObject::Resource.new(base_url+"/#{params[:identifier_type]}/#{params[:identifier]}")
  matches = case params[:identifier_type]
  when "isbn"
    response.collection.find_by_predicate_and_object("[bibo:isbn13]",normalize_isbn(params[:identifier])).keys
  when "lccn"
    response.collection.find_by_predicate_and_object("[bibo:lccn]",normalize_lccn(params[:identifier])).keys
  when "oclc"
    response.collection.find_by_predicate_and_object("[bibo:oclcnum]", params[:identifier]).keys
  else
    ["http://openlibrary.org/#{params[:identifier_type]}/#{params[:identifier]}"]
  end
  matches.each do |match|
    resource.relate("[owl:sameAs]",match)
  end
  collection[resource.uri] = resource
  respond_to do | wants |
    wants.rdf { collection.to_xml }
    wants.json { collection.to_json }
    wants.nt { collection.to_ntriples }
    wants.xml { collection.to_xml }
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
?s dct:isVersionOf ?w.
?w dct:hasVersion ?m .   
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
end
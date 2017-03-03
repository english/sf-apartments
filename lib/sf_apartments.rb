require "lock_jar"
require "speculation"
require "speculation/gen"
require "set"
require "oga"
require "securerandom"

LockJar.load

module SFApartments
  module Listing
    S = Speculation
    using S::NamespacedSymbols.refine(self)

    def self.get_price(doc)
      price_xpath = '/html/body/section/section/h2/span[@class="postingtitletext"]/span[@class="price"]/text()'
      price = doc.at_xpath(price_xpath).text
      Integer(price.sub('$', ''))
    end

    def self.get_move_in_date(doc)
      move_in_date_css = 'div.mapAndAttrs span.housing_movein_now.property_date'
      element = doc.at_css(move_in_date_css)
      Date.parse(element["data-date"])
    end

    def self.get_bed_bath(doc)
      css = "div.mapAndAttrs > p.attrgroup > span:nth-child(1)"
      elements = doc.at_css(css)
      bed_count, _, bath_count = elements.children.to_a
      bed_count = bed_count.text.sub!("BR", "")
      bath_count = bath_count.text.sub!("Ba", "")

      { :bed_count => Float(bed_count), :bath_count => Float(bath_count) }
    end

    def self.get_bed_count(doc)
      get_bed_bath(doc)[:bed_count]
    end

    def self.get_bath(doc)
      get_bed_bath(doc)[:bath_count]
    end

    def self.get_tags(doc)
      xpath = "//div[@class='mapAndAttrs']/p[@class='attrgroup' and position() > 1]/span[@class != 'otherpostings']/text()"
      doc.xpath(xpath).map(&:text).to_set
    end

    def self.get_url(doc)
      url = doc.at_xpath('//link[@rel="canonical"]/@href').value
      URI.parse(url)
    end

    def self.get_body(doc)
      doc.xpath('//section[@id="postingbody"]/text()').text.strip.squeeze("\n")
    end

    def self.parse_page(path, doc)
      { :url.ns          => get_url(doc),
        # :doc.ns          => doc,
        :body.ns         => get_body(doc),
        :price.ns        => get_price(doc),
        :move_in_date.ns => get_move_in_date(doc),
        :bed_count.ns    => get_bed_count(doc),
        :bath_count.ns   => get_bath(doc),
        :tags.ns         => get_tags(doc), }
    end

    S.def(:id.ns, S.with_gen(S.and(String, method(:Integer)), ->(r) {
      Gen.generate(S.gen(:natural_integer.ns(S))).to_s
    }))

    S.def(:url.ns, URI)
    S.def(:price.ns, S.int_in(1_000..10_000))
    S.def(:move_in_date.ns, S.date_in(Date.new(2017, 1, 1)..Date.new(2017, 6, 1)))
    S.def(:bed_count.ns, S.float_in(:min => 0.0, :max => 10.0, :infinite => false, :nan => false))
    S.def(:bath_count.ns, S.float_in(:min => 0.0, :max => 10.0, :infinite => false, :nan => false))

    example_tags = Set["apartment", "laundry in bldg", "carport", "cats are OK - purrr", "dogs are OK - wooof", "loft", "no smoking", "attached garage", "w/d in unit", "condo", "furnished", "detached garage", "off-street parking", "flat", "street parking", "no parking", "laundry on site", "wheelchair accessible"]
    S.def(:tag.ns, S.with_gen(String, S.gen(example_tags)))
    S.def(:tags.ns, S.coll_of(:tag.ns, :kind => Set, :gen_max => 6))
    S.def(:listing.ns(SFApartments), S.keys(:req => [:url.ns, :price.ns, :move_in_date.ns, :bed_count.ns, :bath_count.ns, :tags.ns]))
  end

  module DB
    S = Speculation
    using S::NamespacedSymbols.refine(self)

    java_import "datomic.Peer"
    java_import "datomic.Connection"
    java_import "datomic.Util"

    def self.write_listings(conn, listings)
      prepped = prep_for_datomic(listings)
      conn.transact(prepped).get
    end

    def self.read_listings(conn)
      results = Peer.q(<<-DAT, conn.db)
        [:find (pull ?e [*])
         :where [?e :listing/url ?]]
      DAT

      results.map(&:first).map(&method(:rubyify)).map { |listing|
        listing.map { |k, v|
          if k.namespace == "listing"
            k = k.name.to_sym.ns(SFApartments::Listing)
          end
          [k, v]
        }.to_h
      }
    end

    S.fdef method(:write_listings),
      :args => S.cat(:conn => Connection, :listings => S.coll_of(:listing.ns(SFApartments))),
      :ret  => Java::ClojureLang::PersistentArrayMap

    def self.prep_for_datomic(listings)
      persisted_keys = Set[:url.ns(Listing),
                           :price.ns(Listing),
                           :move_in_date.ns(Listing),
                           :bed_count.ns(Listing),
                           :bath_count.ns(Listing),
                           :tags.ns(Listing),
                           :body.ns(Listing)]

      listings.map { |listing|
        javaify(
          listing.
          select { |k, v| persisted_keys.include?(k) }.
          map { |k, v| [match_db_namespace(k), v] }.
          to_h
        )
      }
    end

    S.fdef method(:prep_for_datomic),
      :args => S.cat(:listings => S.coll_of(:listing.ns(SFApartments))),
      :ret => S.hash_of(String, :any.ns(S))

    def self.match_db_namespace(k)
      k.name.to_sym.ns("listing")
    end

    def self.look_like_clj_symbol(k)
      ":#{k}"
    end

    def self.javaify(x)
      case x
      when Symbol then look_like_clj_symbol(x)
      when Date   then x.to_time.to_java
      when Set    then java.util.HashSet.new(x.to_a)
      when URI    then java.net.URI.new(x.to_s)
      when Hash   then Util.map(*x.map { |k, v| [javaify(k), javaify(v)] }.flatten)
      when Array  then Util.list(*x.map { |x| javaify(x) }.to_a)
      else x
      end
    end

    def self.rubyify(x)
      case x
      when Java::ClojureLang::Keyword then S::NamespacedSymbols.symbol(x.namespace, x.name)
      when Java::JavaUtil::Date       then Time.at(x.time / 1000).to_date
      when Java::JavaUtil::Collection then x.map(&method(:rubyify))
      when Java::JavaNet::URI         then URI(x.to_s)
      when Java::JavaUtil::Map        then x.map { |k, v| [rubyify(k), rubyify(v)] }.to_h
      else x
      end
    end
  end
end

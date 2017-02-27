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
      url = doc.at_xpath('//link[rel=canonical]/@href').value
      java.net.URI.new(url)
    end

    def self.get_body(doc)
      doc.at_xpath('//section[@id=postingbody]/text()').text
    end

    def self.parse_page(path, doc)
      { :"listing/url"          => get_url(doc),
        # :"listing/doc"          => doc,
        :"listing/body"         => get_body(doc),
        :"listing/price"        => get_price(doc),
        :"listing/move_in_date" => get_move_in_date(doc),
        :"listing/bed_count"    => get_bed_count(doc),
        :"listing/bath_count"   => get_bath(doc),
        :"listing/tags"         => get_tags(doc), }
    end

    S.def(:"listing/id", S.with_gen(S.and(String, method(:Integer)), ->(r) {
      Gen.generate(S.gen(:natural_integer.ns(S))).to_s
    }))

    S.def(:"listing/url", S.with_gen(java.net.URI, ->(r) { java.net.URI.new(Gen.generate(S.gen(URI)).to_s) }))
    S.def(:"listing/price", S.int_in(1_000..10_000))
    S.def(:"listing/move_in_date", S.date_in(Date.new(2017, 1, 1)..Date.new(2017, 6, 1)))
    S.def(:"listing/bed_count", S.float_in(:min => 0.0, :max => 10.0, :infinite => false, :nan => false))
    S.def(:"listing/bath_count", S.float_in(:min => 0.0, :max => 10.0, :infinite => false, :nan => false))

    example_tags = Set["apartment", "laundry in bldg", "carport", "cats are OK - purrr", "dogs are OK - wooof", "loft", "no smoking", "attached garage", "w/d in unit", "condo", "furnished", "detached garage", "off-street parking", "flat", "street parking", "no parking", "laundry on site", "wheelchair accessible"]
    S.def(:"listing/tag", S.with_gen(String, S.gen(example_tags)))
    S.def(:"listing/tags", S.coll_of(:"listing/tag", :kind => Set, :gen_max => 6))
    S.def(:"#{SFApartments}/listing", S.keys(:req => [:"listing/url", :"listing/price", :"listing/move_in_date", :"listing/bed_count", :"listing/bath_count", :"listing/tags"]))
  end

  module DB
    S = Speculation
    using S::NamespacedSymbols.refine(self)

    S.def(:"db/listing", S.and(:"#{SFApartments}/listing", S.conformer { |listing|
      persisted_keys = Set[:"listing/url", :"listing/price", :"listing/move_in_date", :"listing/bed_count", :"listing/bath_count", :"listing/tags"]

      listing.
        select { |k, v| persisted_keys.include?(k) }.
        merge(:"listing/move_in_date" => listing.fetch(:"listing/move_in_date").to_time.to_java).
        merge(:"listing/tags" => java.util.HashSet.new(listing.fetch(:"listing/tags").to_a)).
        map { |k, v| [":#{k}", v] }.
        to_h
    }))

    def self.write(conn, listings)
      conformed_listings = listings.map { |listing|
        # raise "invalid listing" unless S.valid?(:"db/listing", listing)
        S.conform(:"db/listing", listing)
      }

      conn.transact(conformed_listings).get
    end

    S.fdef method(:write),
      :args => S.cat(:conn => Java::Datomic::Connection, :listings => S.coll_of(:"SFApartments/listing")),
      :ret  => Java::ClojureLang::PersistentArrayMap
  end
end

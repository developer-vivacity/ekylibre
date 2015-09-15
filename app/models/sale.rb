# = Informations
#
# == License
#
# Ekylibre - Simple agricultural ERP
# Copyright (C) 2008-2009 Brice Texier, Thibaud Merigon
# Copyright (C) 2010-2012 Brice Texier
# Copyright (C) 2012-2015 Brice Texier, David Joulin
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see http://www.gnu.org/licenses.
#
# == Table: sales
#
#  accounted_at        :datetime
#  address_id          :integer
#  affair_id           :integer
#  amount              :decimal(19, 4)   default(0.0), not null
#  annotation          :text
#  client_id           :integer          not null
#  conclusion          :text
#  confirmed_at        :datetime
#  created_at          :datetime         not null
#  creator_id          :integer
#  credit              :boolean          default(FALSE), not null
#  credited_sale_id    :integer
#  currency            :string           not null
#  delivery_address_id :integer
#  description         :text
#  downpayment_amount  :decimal(19, 4)   default(0.0), not null
#  expiration_delay    :string
#  expired_at          :datetime
#  function_title      :string
#  has_downpayment     :boolean          default(FALSE), not null
#  id                  :integer          not null, primary key
#  initial_number      :string
#  introduction        :text
#  invoice_address_id  :integer
#  invoiced_at         :datetime
#  journal_entry_id    :integer
#  letter_format       :boolean          default(TRUE), not null
#  lock_version        :integer          default(0), not null
#  nature_id           :integer
#  number              :string           not null
#  payment_at          :datetime
#  payment_delay       :string           not null
#  pretax_amount       :decimal(19, 4)   default(0.0), not null
#  reference_number    :string
#  responsible_id      :integer
#  state               :string           not null
#  subject             :string
#  transporter_id      :integer
#  updated_at          :datetime         not null
#  updater_id          :integer
#

class Sale < Ekylibre::Record::Base
  attr_readonly :currency
  refers_to :currency
  belongs_to :affair
  belongs_to :client, class_name: 'Entity'
  belongs_to :payer, class_name: 'Entity', foreign_key: :client_id
  belongs_to :address, class_name: 'EntityAddress'
  belongs_to :delivery_address, class_name: 'EntityAddress'
  belongs_to :invoice_address, class_name: 'EntityAddress'
  belongs_to :journal_entry
  belongs_to :nature, class_name: 'SaleNature'
  belongs_to :credited_sale, class_name: 'Sale'
  belongs_to :responsible, -> { contacts }, class_name: 'Entity'
  belongs_to :transporter, class_name: 'Entity'
  has_many :credits, class_name: 'Sale', foreign_key: :credited_sale_id
  has_many :parcels, dependent: :destroy, inverse_of: :sale
  has_many :documents, as: :owner
  has_many :items, -> { order('position, id') }, class_name: 'SaleItem', dependent: :destroy, inverse_of: :sale
  has_many :journal_entries, as: :resource
  has_many :subscriptions, class_name: 'Subscription'
  # [VALIDATORS[ Do not edit these lines directly. Use `rake clean:validations`.
  validates_datetime :accounted_at, :confirmed_at, :expired_at, :invoiced_at, :payment_at, allow_blank: true, on_or_after: Time.new(1, 1, 1, 0, 0, 0, '+00:00')
  validates_numericality_of :amount, :downpayment_amount, :pretax_amount, allow_nil: true
  validates_inclusion_of :credit, :has_downpayment, :letter_format, in: [true, false]
  validates_presence_of :amount, :client, :currency, :downpayment_amount, :number, :payer, :payment_delay, :pretax_amount, :state
  # ]VALIDATORS]
  validates_length_of :currency, allow_nil: true, maximum: 3
  validates_length_of :initial_number, :number, :state, allow_nil: true, maximum: 60
  validates_presence_of :client, :currency, :nature
  validates_presence_of :invoiced_at, if: :invoice?
  validates_delay_format_of :payment_delay, :expiration_delay

  acts_as_numbered :number, readonly: false
  acts_as_affairable :client, debit: :credit?
  accepts_nested_attributes_for :items, reject_if: proc { |item| item[:variant_id].blank? }, allow_destroy: true

  delegate :closed, to: :affair, prefix: true

  scope :invoiced_between, lambda { |started_at, stopped_at|
    where(invoiced_at: started_at..stopped_at)
  }

  scope :estimate_between, lambda { |started_at, stopped_at|
    where(accounted_at: started_at..stopped_at, state: :estimate)
  }

  scope :unpaid, -> { where(state: %w(order invoice)).where('payment_at IS NULL OR payment_at <= ?', Time.now).where.not(affair: Affair.closeds) }

  state_machine :state, initial: :draft do
    state :draft
    state :estimate
    state :refused
    state :order
    state :invoice
    state :aborted

    event :propose do
      transition draft: :estimate, if: :has_content?
      transition refused: :estimate
    end
    event :correct do
      transition estimate: :draft
      transition refused: :draft
      transition order: :draft # , if: lambda{|sale| !sale.partially_closed?}
    end
    event :refuse do
      transition estimate: :refused, if: :has_content?
    end
    event :confirm do
      transition estimate: :order, if: :has_content?
    end
    event :invoice do
      transition [:draft, :estimate, :order] => :invoice, if: :has_content?
    end
    event :abort do
      transition draft: :aborted
      transition estimate: :aborted
    end
  end

  before_validation(on: :create) do
    self.state ||= :draft
    self.currency = nature.currency if nature
    self.created_at = Time.now
  end

  before_validation do
    if address.nil? && client
      dc = client.default_mail_address
      self.address_id = dc.id if dc
    end
    self.delivery_address_id ||= address_id
    self.invoice_address_id ||= self.delivery_address_id
    self.created_at ||= Time.now
    self.nature ||= SaleNature.by_default if nature.nil?
    if self.nature
      self.expiration_delay ||= self.nature.expiration_delay
      self.expired_at ||= Delay.new(self.expiration_delay).compute(self.created_at)
      self.payment_delay ||= self.nature.payment_delay
      self.has_downpayment = self.nature.downpayment if has_downpayment.nil?
      self.downpayment_amount ||= (amount * self.nature.downpayment_percentage * 0.01) if amount >= self.nature.downpayment_minimum
      self.currency ||= self.nature.currency
    end
    true
  end

  validate do
    if invoiced_at
      errors.add(:invoiced_at, :before, restriction: Time.now.l) if invoiced_at > Time.now
    end
    for mail_address in [:address, :delivery_address, :invoice_address]
      if send(mail_address)
        unless send(mail_address).mail?
          errors.add(mail_address, :must_be_a_mail_address)
        end
      end
    end
  end

  before_update do
    old = self.class.find(id)
    if old.invoice?
      for attr in self.class.columns_definition.keys
        send(attr + '=', old.send(attr))
      end
    end
  end

  after_create do
    client.add_event(:sale_creation, updater.person) if updater && updater.person
  end

  # This callback bookkeeps the sale depending on its state
  bookkeep do |b|
    b.journal_entry(self.nature.journal, printed_on: invoiced_on, if: (self.nature.with_accounting? && self.invoice?)) do |entry|
      label = tc(:bookkeep, resource: state_label, number: number, client: client.full_name, products: (description.blank? ? items.pluck(:label).to_sentence : description), sale: initial_number)
      entry.add_debit(label, client.account(:client).id, amount) unless amount.zero?
      for item in items
        entry.add_credit(label, (item.account || item.variant.product_account).id, item.pretax_amount) unless item.pretax_amount.zero?
        entry.add_credit(label, item.tax.collect_account_id, item.taxes_amount) unless item.taxes_amount.zero?
      end
    end
  end

  def invoiced_on
    dealt_at.to_date
  end

  # Gives the date to use for affair bookkeeping
  def dealt_at
    (self.invoice? ? invoiced_at : self.created_at)
  end

  # Gives the amount to use for affair bookkeeping
  def deal_amount
    ((self.aborted? || self.refused?) ? 0 : self.credit? ? -amount : amount)
  end

  # Globalizes taxes into an array of hash
  def deal_taxes(mode = :debit)
    return [] if deal_mode_amount(mode).zero?
    taxes = {}
    coeff = (self.credit? ? -1 : 1).to_d
    # coeff *= (self.send("deal_#{mode}?") ? 1 : -1)
    for item in items
      taxes[item.tax_id] ||= { amount: 0.0.to_d, tax: item.tax }
      taxes[item.tax_id][:amount] += coeff * item.amount
    end
    taxes.values
  end

  def partially_closed?
    !affair.debit.zero? && !affair.credit.zero?
  end

  def supplier
    Entity.of_company
  end

  delegate :number, to: :client, prefix: true

  def nature=(value)
    super(value)
    self.currency = self.nature.currency if self.nature
  end

  # Save a new time
  def refresh
    save
  end

  # Test if there is some items in the sale.
  def has_content?
    items.any?
  end

  # Returns if the sale has been validated and so if it can be
  # considered as sold.
  def sold?
    (self.order? || self.invoice?)
  end

  # Remove all bad dependencies and return at draft state with no parcels
  def correct
    return false unless self.can_correct?
    parcels.clear
    super
  end

  # Confirm the sale order. This permits to define parcels and assert validity of sale
  def confirm(confirmed_at = Time.now)
    return false unless self.can_confirm?
    update_column(:confirmed_at, confirmed_at || Time.now)
    super
  end

  # Invoices all the products creating the delivery if necessary.
  # Changes number with an invoice number saving exiting number in +initial_number+.
  def invoice(invoiced_at = Time.now)
    return false unless self.can_invoice?
    ActiveRecord::Base.transaction do
      # Set values for invoice
      self.invoiced_at ||= invoiced_at
      self.confirmed_at ||= self.invoiced_at
      self.payment_at ||= Delay.new(self.payment_delay).compute(self.invoiced_at)
      self.initial_number = number
      if sequence = Sequence.of(:sales_invoices)
        loop do
          self.number = sequence.next_value
          break unless self.class.find_by(number: number, state: 'invoice')
        end
      end
      self.save!
      client.add_event(:sales_invoice_creation, updater.person) if updater
      return super
    end
    false
  end

  def duplicatable?
    !credit
  end

  # Duplicates a +sale+ in 'E' mode with its items and its active subscriptions
  def duplicate(attributes = {})
    fail StandardError, 'Uncancelable sale' unless self.duplicatable?
    hash = [:client_id, :nature_id, :currency, :letter_format, :annotation, :subject, :function_title, :introduction, :conclusion, :description, :currency].inject({}) do |h, field|
      h[field] = send(field)
      h
    end.merge(attributes)
    # Items
    items_attributes = {}
    items.each_with_index do |item, index|
      items_attributes[index] = [:variant_id, :quantity, :amount, :currency, :label, :position, :pretax_amount, :reduction_percentage, :tax_id, :unit_amount, :unit_pretax_amount].inject({}) do |h, field|
        h[field] = item.send(field)
        # Subscriptions
        h[:subscriptions_attributes] = {}
        subscriptions.where(suspended: false).each_with_index do |subscription, j|
          h[:subscriptions_attributes][j] = [:subscriber_id, :address_id, :quantity_id, :nature_id, :product_nature_id].inject({}) do |sh, field|
            sh[field] = subscription.send(field)
            sh
          end
        end
        h
      end
    end
    hash[:items_attributes] = items_attributes
    self.class.create!(hash)
  end

  # Prints human name of current state
  def state_label
    self.class.state_machine.state(self.state.to_sym).human_name
  end

  # Returns true if there is some products to deliver
  def deliverable?
    # not self.undelivered(:quantity).zero? and (self.invoice? or self.order?)
    # !self.undelivered_items.count.zero? and (self.invoice? or self.order?)
    true
  end

  # Label of the sales order depending on the state and the number
  def name
    tc("label.#{(self.credit? && self.invoice?) ? :credit : self.state}", number: number)
  end
  alias_method :label, :name

  # Alias for letter_format? method
  def letter?
    self.letter_format?
  end

  def mail_address
    (address || client.default_mail_address).mail_coordinate
  end

  def number_label
    tc('number_label.' + (self.estimate? ? 'proposal' : 'command'), number: number)
  end

  def taxes_amount
    amount - pretax_amount
  end

  def usable_payments
    client.incoming_payments.where('COALESCE(used_amount, 0)<COALESCE(amount, 0)').joins(mode: :cash).where(currency: self.currency).order('to_bank_at')
  end

  def sales_mentions
    # get preference for sales conditions
    preference_sales_conditions = Preference.global.find_by(name: :sales_conditions)
    if preference_sales_conditions
      return preference_sales_conditions.value
    else
      return nil
    end
  end

  # Build general sales condition for the sale order
  def sales_conditions
    c = []
    c << tc('sales_conditions.downpayment', percentage: self.nature.downpayment_percentage, amount: self.downpayment_amount.l(currency: self.currency)) if amount > self.nature.downpayment_minimum
    c << tc('sales_conditions.validity', expiration: self.expired_at.l)
    c += self.nature.sales_conditions.to_s.split(/\s*\n\s*/) if self.nature.sales_conditions
    # c += self.responsible.team.sales_conditions.to_s.split(/\s*\n\s*/) if self.responsible and self.responsible.team
    c
  end

  def unpaid_days
    (Time.now - self.invoiced_at) if self.invoice?
  end

  def products
    p = []
    for item in items
      p << item.product.name
    end
    ps = p.join(', ')
  end

  # Returns true if sale is cancellable as an invoice
  def cancellable?
    !self.credit? && self.invoice? && amount + credits.sum(:amount) > 0
  end

  # Build a new sale with new items ready for correction and save
  def build_credit
    attrs = [:affair, :client, :address, :responsible, :nature, :currency, :invoice_address, :transporter].inject({}) do |hash, attribute|
      hash[attribute] = send(attribute) unless send(attribute).nil?
      hash
    end
    attrs[:invoiced_at] = Time.now
    attrs[:credit] = true
    attrs[:credited_sale] = self
    sale_credit = Sale.new(attrs)
    items.each do |item|
      attrs = [:account, :currency, :variant, :unit_pretax_amount, :unit_amount, :reduction_percentage, :tax].inject({}) do |hash, attribute|
        hash[attribute] = item.send(attribute) unless item.send(attribute).nil?
        hash
      end
      attrs[:credited_quantity] = item.creditable_quantity
      attrs[:credited_item] = item
      if attrs[:credited_quantity] > 0
        sale_credit_item = sale_credit.items.build(attrs)
        sale_credit_item.valid?
      end
    end
    # sale_credit.valid?
    sale_credit
  end

  # Returns status of affair if invoiced else "stop"
  def status
    return affair.status if self.invoice? && affair
    :stop
  end
end

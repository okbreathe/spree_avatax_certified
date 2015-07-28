require 'logging'
require_dependency 'spree/order'

module Spree
  class AvalaraTransaction < ActiveRecord::Base
    AVALARA_TRANSACTION_LOGGER = AvataxHelper::AvataxLog.new('post_order_to_avalara', __FILE__)

    belongs_to :order
    belongs_to :reimbursement
    belongs_to :refund
    validates :order, presence: true
    has_many :adjustments, as: :source

    def rnt_tax
      @myrtntax
    end

    def amount
      @myrtntax
    end

    def lookup_avatax
      order_details = Spree::Order.find(self.order_id)
      post_order_to_avalara(false, order_details.line_items, order_details)
    end

    def commit_avatax(items, order_details, doc_id = nil, org_ord_date = nil, invoice_dt = nil)
      if invoice_dt == 'ReturnInvoice'
        post_return_order_to_avalara(false, items, order_details, doc_id, org_ord_date, invoice_dt)
      else
        post_order_to_avalara(false, items, order_details, doc_id, org_ord_date, invoice_dt)
      end
    end

    def commit_avatax_final(items, order_details, doc_id = nil, org_ord_date = nil, invoice_dt = nil)
      if document_committing_enabled?
        if invoice_dt == 'ReturnInvoice'
          post_return_order_to_avalara(true, items, order_details, doc_id, org_ord_date,invoice_dt)
        else
          post_order_to_avalara(true, items, order_details, doc_id, org_ord_date, invoice_dt)
        end
      else
        AVALARA_TRANSACTION_LOGGER.debug 'avalara document committing disabled'
        'avalara document committing disabled'
      end
    end

    def check_status(order)
      if order.state == 'canceled'
        cancel_order_to_avalara('SalesInvoice', 'DocVoided', order)
      end
    end

    def update_adjustment(adjustment, source)
      AVALARA_TRANSACTION_LOGGER.info('update adjustment call')

      if adjustment.state != 'closed'
        commit_avatax(order.line_items, order)
        adjustment.update_column(:amount, rnt_tax)
      end

      if order.complete?
        commit_avatax_final(order.line_items, order)
        adjustment.update_column(:amount, rnt_tax)
        adjustment.update_column(:state, 'closed')
      end

      if order.state == 'canceled'
        cancel_order_to_avalara('SalesInvoice', 'DocVoided', order)
      end

      if adjustment.state == 'closed' && order.adjustments.reimbursement.exists?
        commit_avatax(order.line_items, order, order.number.to_s + ':' + order.adjustments.reimbursement.first.id.to_s, order.completed_at)

        if rnt_tax != '0.00'
          adjustment.update_column(:amount, rnt_tax)
          adjustment.update_column(:state, 'closed')
        end
      end

      if adjustment.state == 'closed' && order.adjustments.reimbursement.exists?
        order.adjustments.reimbursement.each do |adj|
          if adj.state == 'closed' || adj.state == 'closed'
            commit_avatax_final(order.line_items, order, order.number.to_s + ':' + adj.id.to_s, order.completed_at )
          end
        end

        if rnt_tax != '0.00'
          adjustment.update_column(:amount, rnt_tax)
          adjustment.update_column(:state, 'closed')
        end
      end
    end

    private

    def create_avatax_origin(origin)
      Spree::StockLocation.create(
        name: 'avatax origin',
        address1: origin['Address1'],
        address2: origin['Address2'],
        city: origin['City'],
        state_id: Spree::State.find_by_name(origin['Region']).id,
        state_name: origin['Region'],
        zipcode: origin['Zip5'],
        country_id: Spree::State.find_by_name(origin['Region']).country_id
      )
    end

    def get_shipped_from_address(item_id)
      AVALARA_TRANSACTION_LOGGER.info('shipping address get')

      stock_item = Stock_Item.find(item_id)
      shipping_address = stock_item.stock_location || nil
      shipping_address
    end

    def cancel_order_to_avalara(doc_type = 'SalesInvoice', cancel_code = 'DocVoided', order_details = nil)
      AVALARA_TRANSACTION_LOGGER.info('cancel order to avalara')

      cancel_tax_request = {
        :CompanyCode => Spree::Config.avatax_company_code,
        :DocType => doc_type,
        :DocCode => order_details.number,
        :CancelCode => cancel_code
      }

      AVALARA_TRANSACTION_LOGGER.debug cancel_tax_request

      mytax = TaxSvc.new
      cancel_tax_result = mytax.cancel_tax(cancel_tax_request)

      AVALARA_TRANSACTION_LOGGER.debug cancel_tax_result

      if cancel_tax_result == 'error in Tax'
        return 'Error in Tax'
      else
        if cancel_tax_result['ResultCode'] == 'Success'
          AVALARA_TRANSACTION_LOGGER.debug cancel_tax_result
          return cancel_tax_result
        end
      end
    end

    def origin_address
      origin = JSON.parse(Spree::Config.avatax_origin)
      orig_address = {}
      orig_address[:AddressCode] = 'Orig'
      orig_address[:Line1] = origin['Address1']
      orig_address[:City] = origin['City']
      orig_address[:PostalCode] = origin['Zip5']
      orig_address[:Country] = origin['Country']
      AVALARA_TRANSACTION_LOGGER.debug orig_address.to_xml
      orig_address
    end

    def origin_ship_address(line_item, origin)
      orig_ship_address = {}
      orig_ship_address[:AddressCode] = line_item.id
      orig_ship_address[:Line1] = origin.address1
      orig_ship_address[:City] = origin.city
      orig_ship_address[:PostalCode] = origin.zipcode
      orig_ship_address[:Country] = Spree::Country.find(origin.country_id).iso

      AVALARA_TRANSACTION_LOGGER.debug orig_ship_address.to_xml
      orig_ship_address
    end

    def order_shipping_address
      unless order.ship_address.nil?
        shipping_address = {}
        shipping_address[:AddressCode] = 'Dest'
        shipping_address[:Line1] = order.ship_address.address1
        shipping_address[:Line2] = order.ship_address.address2
        shipping_address[:City] = order.ship_address.city
        shipping_address[:Region] = order.ship_address.state_text
        shipping_address[:Country] = Spree::Country.find(order.ship_address.country_id).iso
        shipping_address[:PostalCode] = order.ship_address.zipcode

        AVALARA_TRANSACTION_LOGGER.debug shipping_address.to_xml
        shipping_address
      end
    end

    def stock_location(packages, line_item)
      stock_loc = nil

      packages.each do |package|
        next unless package.to_shipment.stock_location.stock_items.where(:variant_id => line_item.variant.id).exists?
        stock_loc = package.to_shipment.stock_location
        AVALARA_TRANSACTION_LOGGER.debug stock_loc
      end
      stock_loc
    end

    def shipment_line(shipment)
      line = {}
      line[:LineNo] = "#{shipment.id}-FR"
      line[:ItemCode] = 'Shipping'
      line[:Qty] = 1
      line[:Amount] = shipment.cost.to_f
      line[:OriginCode] = 'Orig'
      line[:DestinationCode] = 'Dest'
      line[:CustomerUsageType] = myusecode.try(:use_code)
      line[:Description] = 'Shipping Charge'
      line[:TaxCode] = shipment.shipping_method.tax_code || 'FR000000'

      AVALARA_TRANSACTION_LOGGER.debug line.to_xml
      line
    end

    def reimbursement_return_item_line(return_item)
      line = {}
      line[:LineNo] = "#{return_item.inventory_unit.line_item_id}-RA-#{return_item.reimbursement_id}"
      line[:ItemCode] = return_item.inventory_unit.line_item.sku || 'Reimbursement'
      line[:Qty] = 1
      line[:Amount] = -return_item.pre_tax_amount.to_f
      line[:OriginCode] = 'Orig'
      line[:DestinationCode] = 'Dest'
      line[:CustomerUsageType] = myusecode.try(:use_code)
      line[:Description] = 'Reimbursement'
      if return_item.variant.tax_category.tax_code.nil?
        line[:TaxCode] = 'P0000000'
      else
        line[:TaxCode] = return_item.variant.tax_category.tax_code
      end

      AVALARA_TRANSACTION_LOGGER.debug line.to_xml
      line
    end

    def refund_line(refund)
      line = {}
      line[:LineNo] = "#{refund.id}-RA"
      line[:ItemCode] = refund.transaction_id || 'Refund'
      line[:Qty] = 1
      line[:Amount] = -refund.pre_tax_amount.to_f
      line[:OriginCode] = 'Orig'
      line[:DestinationCode] = 'Dest'
      line[:CustomerUsageType] = myusecode.try(:use_code)
      line[:Description] = 'Refund'

      AVALARA_TRANSACTION_LOGGER.debug line.to_xml
      line
    end

    def myusecode
      begin
        if !order.user_id.nil?
          myuserid = order.user_id
          AVALARA_TRANSACTION_LOGGER.debug myuserid
          myuser = Spree::User.find(myuserid)
          unless myuser.avalara_entity_use_code_id.nil?
            return Spree::AvalaraEntityUseCode.find(myuser.avalara_entity_use_code_id)
          else
            return nil
          end
        end
      rescue => e
        AVALARA_TRANSACTION_LOGGER.debug e
        AVALARA_TRANSACTION_LOGGER.debug "error with order's user id"
      end
    end

    def backup_stock_location(origin)
      location = Spree::StockLocation.find_by(default: true)
      avatax_origin_location = Spree::StockLocation.find_by(name: 'avatax origin')

      if location.nil? && avatax_origin_location.nil?
        AVALARA_TRANSACTION_LOGGER.info('avatax origin location created')
        return create_avatax_origin origin
      elsif location.nil? || location.city.nil?

        if avatax_origin_location.nil?
          return create_avatax_origin origin
        elsif avatax_origin_location.city.nil?
          AVALARA_TRANSACTION_LOGGER.info('avatax origin location updated avatax origin')
          return avatax_origin_location.update_attributes(
            address1: origin['Address1'],
            address2: origin['Address2'],
            city: origin['City'],
            state_id: Spree::State.find_by_name(origin['Region']).id,
            state_name: origin['Region'],
            zipcode: origin['Zip5'],
            country_id: Spree::State.find_by_name(origin['Region']).country_id
          )
        else
          AVALARA_TRANSACTION_LOGGER.info('avatax origin location')
          return avatax_origin_location
        end
      else
        AVALARA_TRANSACTION_LOGGER.info('default location')
        return location
      end
    end

    def post_order_to_avalara(commit = false, orderitems = nil, order_details = nil, doc_code = nil, org_ord_date = nil, invoice_detail = nil)
      AVALARA_TRANSACTION_LOGGER.info('post order to avalara')
      address_validator = AddressSvc.new
      tax_line_items = []
      addresses = []
      origin = JSON.parse(Spree::Config.avatax_origin)

      i = 0

      if orderitems
        orderitems.each do |line_item|
          line = {}
          i += 1

          line[:LineNo] = line_item.id
          line[:ItemCode] = line_item.variant.sku
          line[:Qty] = line_item.quantity
          line[:Amount] = line_item.amount.to_f
          line[:OriginCode] = 'Orig'
          line[:DestinationCode] = 'Dest'

          AVALARA_TRANSACTION_LOGGER.info('about to check for User')
          AVALARA_TRANSACTION_LOGGER.debug myusecode

          line[:CustomerUsageType] = myusecode.try(:use_code)

          AVALARA_TRANSACTION_LOGGER.info('after user check')

          if line_item.promo_total.to_f != 0
            line[:Discounted] = true
          elsif order_details.all_adjustments.where(source_type: 'Spree::PromotionAction').where(adjustable_type: 'Spree::Order')
            line[:Discounted] = true
          else
            line[:Discounted] = false
          end

          line[:Description] = line_item.name
          line[:TaxCode] = line_item.tax_category.try(:tax_code) || 'P0000000'

          AVALARA_TRANSACTION_LOGGER.info('about to check for shipped from')

          packages = Spree::Stock::Coordinator.new(order_details).packages

          AVALARA_TRANSACTION_LOGGER.info('packages')
          AVALARA_TRANSACTION_LOGGER.debug packages
          AVALARA_TRANSACTION_LOGGER.debug backup_stock_location(origin)
          AVALARA_TRANSACTION_LOGGER.info('checked for shipped from')


          if stock_location(packages, line_item)
            addresses << origin_ship_address(line_item, stock_location(packages, line_item))
          elsif backup_stock_location(origin)
            addresses << origin_ship_address(line_item, location)
          end

          line[:OriginCode] = line_item.id
          AVALARA_TRANSACTION_LOGGER.debug line.to_xml

          tax_line_items << line
        end
      end

      AVALARA_TRANSACTION_LOGGER.info('running order details')

      if order_details
        AVALARA_TRANSACTION_LOGGER.info('order adjustments')
        order_details.shipments.each do |shipment|
          tax_line_items << shipment_line(shipment)
        end
      end

      if order_details.ship_address.nil?
        order_details.update_attributes(ship_address_id: order_details.bill_address_id)
      end

      response = address_validator.validate(order_details.ship_address)

      if !response.nil?
        if response['ResultCode'] == 'Success'
          AVALARA_TRANSACTION_LOGGER.info('Address Validation Success')
        else
          AVALARA_TRANSACTION_LOGGER.info('Address Validation Failed')
        end
      end

      addresses << order_shipping_address
      addresses << origin_address

      get_taxes = {
        :CustomerCode => order_details.user ? order_details.user.id : 'Guest',
        :DocDate => org_ord_date ? org_ord_date : Date.current.to_formatted_s(:db),

        :CompanyCode => Spree::Config.avatax_company_code,
        :CustomerUsageType => myusecode.try(:use_code),
        :ExemptionNo => order_details.user.try(:exemption_number),
        :Client =>  AVATAX_CLIENT_VERSION || 'SpreeExtV3.0',
        :DocCode => doc_code ? doc_code : order_details.number,

        :Discount => order_details.all_adjustments.where(source_type: 'Spree::PromotionAction').any? ? order_details.all_adjustments.where(source_type: 'Spree::PromotionAction').pluck(:amount).reduce(&:+).to_f.abs : 0,

        :ReferenceCode => order_details.number,
        :DetailLevel => 'Tax',
        :Commit => commit,
        :DocType => invoice_detail ? invoice_detail : 'SalesOrder',
        :Addresses => addresses,
        :Lines => tax_line_items
      }

      AVALARA_TRANSACTION_LOGGER.debug get_taxes

      mytax = TaxSvc.new

      get_tax_result = mytax.get_tax(get_taxes)

      AVALARA_TRANSACTION_LOGGER.debug get_tax_result

      if get_tax_result == 'error in Tax'
        @myrtntax = { TotalTax: '0.00' }
      else
        if get_tax_result['ResultCode'] == 'Success'
          AVALARA_TRANSACTION_LOGGER.info 'total tax'
          AVALARA_TRANSACTION_LOGGER.debug get_tax_result['TotalTax'].to_s
          @myrtntax = get_tax_result
        end
      end
      return @myrtntax
    end

    def post_return_order_to_avalara(commit = false, orderitems = nil, order_details = nil, doc_code = nil, org_ord_date = nil, invoice_detail = nil)
      tax_line_items = []
      addresses = []
      AVALARA_TRANSACTION_LOGGER.info('starting post return order to avalara')
      AVALARA_TRANSACTION_LOGGER.info('running order details')

      if order_details
        AVALARA_TRANSACTION_LOGGER.info('order adjustments')

        order_details.reimbursements.each do |reimbursement|
          next if reimbursement.reimbursement_status == 'reimbursed'
          reimbursement.return_items.each do |return_item|
            tax_line_items << reimbursement_return_item_line(return_item)
          end
        end

        order_details.refunds.each do |refund|
          next unless refund.reimbursement_id.nil?
          tax_line_items << refund_line(refund)
        end
      end

      if order_details.ship_address.nil?
        order_details.update_attributes(ship_address_id: order_details.bill_address_id)
      end

      addresses << order_shipping_address
      addresses << origin_address

      taxoverride = {}

      taxoverride[:TaxOverrideType] = 'TaxDate'
      taxoverride[:Reason] = 'Adjustment for return'
      taxoverride[:TaxDate] = org_ord_date
      taxoverride[:TaxAmount] = '0'

      get_taxes = {
        :CustomerCode => order_details.user ? order_details.user.id : 'Guest',
        :DocDate => org_ord_date ? org_ord_date : Date.current.to_formatted_s(:db),

        :CompanyCode => Spree::Config.avatax_company_code,
        :CustomerUsageType => myusecode.try(:use_code),
        :ExemptionNo => order_details.user.try(:exemption_number),
        :Client =>  AVATAX_CLIENT_VERSION || 'SpreeExtV3.0',
        :DocCode => doc_code ? doc_code : order_details.number,

        :ReferenceCode => order_details.number,
        :DetailLevel => 'Tax',
        :Commit => commit,
        :DocType => invoice_detail ? invoice_detail : 'ReturnOrder',
        :Addresses => addresses,
        :Lines => tax_line_items
      }

      get_taxes[:TaxOverride] = taxoverride

      AVALARA_TRANSACTION_LOGGER.debug get_taxes

      mytax = TaxSvc.new

      get_tax_result = mytax.get_tax(get_taxes)
      AVALARA_TRANSACTION_LOGGER.debug get_tax_result

      if get_tax_result == 'error in Tax'
        @myrtntax = { TotalTax: '0.00' }
      else
        if get_tax_result['ResultCode'] == 'Success'
          AVALARA_TRANSACTION_LOGGER.info 'total tax'
          AVALARA_TRANSACTION_LOGGER.debug get_tax_result['TotalTax'].to_s
          @myrtntax = get_tax_result
        end
      end
      return @myrtntax
    end

    def document_committing_enabled?
      Spree::Config.avatax_document_commit
    end
  end
end

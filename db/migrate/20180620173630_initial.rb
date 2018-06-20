class Initial < ActiveRecord::Migration[5.1]
  def change
    create_table :spree_avalara_transactions do |t|
      t.references :order
      t.references :reimbursement
      t.string :message

      t.timestamps
    end

    create_table :spree_avalara_entity_use_codes do |t|
      t.string :use_code
      t.string :use_code_description
      t.timestamps
    end

    add_reference :spree_avalara_transactions, :refund, index: true

    user_table = Spree.user_class.table_name

    add_column user_table, :exemption_number, :string
    add_column user_table, :avalara_entity_use_code_id, :integer
    add_column user_table, :vat_id, :string
    add_column :spree_shipping_methods, :tax_code, :string
  end
end

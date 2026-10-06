# frozen_string_literal: true

class AddDLog2ToPoints < ActiveRecord::Migration[8.0]
  def up
    return if column_exists?(:points, :d_log2)

    add_column :points, :d_log2, :smallint
  end

  def down
    return unless column_exists?(:points, :d_log2)

    remove_column :points, :d_log2
  end
end

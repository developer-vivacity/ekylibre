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
# == Table: manure_management_plan_zones
#
#  absorbed_nitrogen_at_opening                    :decimal(19, 4)
#  administrative_area                             :string
#  computation_method                              :string           not null
#  created_at                                      :datetime         not null
#  creator_id                                      :integer
#  cultivation_variety                             :string
#  expected_yield                                  :decimal(19, 4)
#  humus_mineralization                            :decimal(19, 4)
#  id                                              :integer          not null, primary key
#  intermediate_cultivation_residue_mineralization :decimal(19, 4)
#  irrigation_water_nitrogen                       :decimal(19, 4)
#  lock_version                                    :integer          default(0), not null
#  maximum_nitrogen_input                          :decimal(19, 4)
#  meadow_humus_mineralization                     :decimal(19, 4)
#  mineral_nitrogen_at_opening                     :decimal(19, 4)
#  nitrogen_at_closing                             :decimal(19, 4)
#  nitrogen_input                                  :decimal(19, 4)
#  nitrogen_need                                   :decimal(19, 4)
#  organic_fertilizer_mineral_fraction             :decimal(19, 4)
#  plan_id                                         :integer          not null
#  previous_cultivation_residue_mineralization     :decimal(19, 4)
#  soil_nature                                     :string
#  soil_production                                 :decimal(19, 4)
#  support_id                                      :integer          not null
#  updated_at                                      :datetime         not null
#  updater_id                                      :integer
#
class ManureManagementPlanZone < Ekylibre::Record::Base
  belongs_to :plan, class_name: 'ManureManagementPlan', inverse_of: :zones
  belongs_to :support, class_name: 'ProductionSupport'
  has_one :activity, through: :production
  has_one :campaign, through: :plan
  has_one :cultivable_zone, through: :support, source: :storage
  has_one :production, through: :support
  refers_to :computation_method, class_name: 'ManureManagementPlanComputationMethod'
  refers_to :soil_nature
  refers_to :cultivation_variety, class_name: 'Variety'
  refers_to :administrative_area
  # [VALIDATORS[ Do not edit these lines directly. Use `rake clean:validations`.
  validates_numericality_of :absorbed_nitrogen_at_opening, :expected_yield, :humus_mineralization, :intermediate_cultivation_residue_mineralization, :irrigation_water_nitrogen, :maximum_nitrogen_input, :meadow_humus_mineralization, :mineral_nitrogen_at_opening, :nitrogen_at_closing, :nitrogen_input, :nitrogen_need, :organic_fertilizer_mineral_fraction, :previous_cultivation_residue_mineralization, :soil_production, allow_nil: true
  validates_presence_of :computation_method, :plan, :support
  # ]VALIDATORS]

  delegate :locked?, :opened_at, to: :plan
  delegate :name, to: :cultivable_zone

  scope :selecteds, -> { joins(:plan).merge(ManureManagementPlan.selecteds) }

  protect do
    self.locked?
  end

  def estimate_expected_yield
    if computation_method
      self.expected_yield = Calculus::ManureManagementPlan.estimate_expected_yield(parameters).to_f(plan.mass_density_unit)
    end
  end

  def compute
    for name, value in Calculus::ManureManagementPlan.compute(parameters)
      if %w(absorbed_nitrogen_at_opening expected_yield humus_mineralization intermediate_cultivation_residue_mineralization irrigation_water_nitrogen maximum_nitrogen_input meadow_humus_mineralization mineral_nitrogen_at_opening nitrogen_at_closing nitrogen_input nitrogen_need organic_fertilizer_mineral_fraction previous_cultivation_residue_mineralization soil_production).include?(name.to_s)
        send("#{name}=", value.to_f(:kilogram_per_hectare))
      end
    end
    self.save!
  end

  def parameters
    hash = {
      available_water_capacity: available_water_capacity,
      opened_at: opened_at,
      support: support
    }
    if support.production_usage
      hash[:production_usage] = Nomen::ProductionUsages[support.production_usage]
    end
    if computation_method
      hash[:method] = Nomen::ManureManagementPlanComputationMethods[computation_method]
    end
    if administrative_area
      hash[:administrative_area] = Nomen::AdministrativeAreas[administrative_area]
    end
    if cultivation_variety
      hash[:variety] = Nomen::Varieties[cultivation_variety]
    end
    hash[:soil_nature] = Nomen::SoilNatures[soil_nature] if soil_nature
    if expected_yield
      hash[:expected_yield] = expected_yield.in(plan.mass_density_unit)
    end
    hash
  end

  # TODO: Compute available from parcels or CZ ?
  def available_water_capacity
    0.0.in_liter_per_hectare
  end

  # To have human_name in report
  def soil_nature_name
    unless item = Nomen::SoilNatures[soil_nature].human_name
      return nil
    end
    item
  end

  def cultivation_variety_name
    unless item = Nomen::Varieties[cultivation_variety].human_name
      return nil
    end
    item
  end
end
